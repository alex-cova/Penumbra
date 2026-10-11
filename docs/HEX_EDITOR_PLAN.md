# Hex editor: binary and unknown files open in a hexadecimal editor

## Context
Today a file Umbra cannot show as text either fails with an error or opens as garbage:

- `IDEWorkspace.loadDocument(from:)` (`Example/Umbra/IDEWorkspace.swift`, ~:3924) sends images to `WorkbenchDocument.loadImage` and everything else to `WorkbenchDocument.load`.
- `WorkbenchDocument.load` throws `DocumentLoadError.invalidEncoding` for bytes that are not UTF-8 and that `TextFileEncoding.guess` calls binary (`WorkbenchDocument.swift` `prepareGuessing`, `TextFileEncoding.swift` `guess`). `openDocument(from:)` turns that into an error alert.
- A binary file whose bytes happen to be valid UTF-8 (NUL is valid UTF-8, so most binaries with a mostly-ASCII start) opens as text full of control characters. Nothing checks for NUL on the open path; only Find in Files (`ProjectSearchEngine.swift` ~:275) and Local History (`IDELocalHistoryStore.swift` ~:72) skip such files.

The goal: when the editor is asked to open a file that is not text, or whose type it does not know and whose content is not text, it opens in a **hex editor** tab instead. The user can also switch a file between Text and Hex by hand, and edit and save bytes.

Everything the user sees is Umbra (`Example/Umbra`). The detector and the document kind are small, pure additions to `Penumbra`; the byte model is a new library with no dependency on `Penumbra`, in the same spirit as `SubprocessKit` and `JavaIntelligence`.

## Decisions (fixed here so the phases do not re-argue them)

| Question | Decision | Why |
|---|---|---|
| What counts as "unknown"? | A file whose extension/name is not a known text or source type **and** whose first 8 KB does not look like text. A text file with an unknown extension (`LICENSE`, `.foo`, `Makefile.inc`) still opens as text. | Opening every unknown-extension file as hex would be a regression for config and dotfiles. |
| Known text type with undecodable bytes | Falls back to hex instead of an error. Explicit "Reopen with Encoding" keeps today's error. | The user asked for text, but the alternative is a dead end. A "Reopen as Text" action is always offered. |
| Known text type with NULs but valid UTF-8 | Stays text. | The extension is the user's stated intent; "Reopen as Hex" is one click. |
| Reading bytes | `pread` through a bounded page cache, not `mmap`. | A mapped file that is truncated by another process raises SIGBUS. Penumbra works around it with a private `clonefile` copy; a hex view of a multi-GB file should not clone it. `pread` also makes external changes just a cache invalidation. |
| Scrolling | Own virtual scroll over `topRow: Int64`; the view is viewport-sized. | A 4 GB file is 268 M rows at 16 bytes; a document view that tall breaks AppKit and layer tiling (floating-point limits well below that). |
| Edit model | Piece table over the original file plus an append-only added buffer; **overwrite** mode by default, **insert** mode switchable. | Overwrite keeps length and offsets stable, which is what people editing a binary expect. A piece table makes insert and delete O(pieces), never O(file). |
| Where the pieces live | `HexKit` (model, no AppKit) in the root package; view and workspace glue in `Example/Umbra/HexEditor/`; `.binary` content kind and detector in `Penumbra`. | Keeps `Penumbra` free of a hex view that only Umbra needs, and lets the model be tested without a display. |

## 1. Detection (`Penumbra`, pure)
`Sources/Penumbra/Workbench/BinaryContentDetector.swift`, next to `ImageContentDetector.swift`. Public, no AppKit, App Store safe.

```swift
public enum BinaryContentDetector {
    public enum Classification: Equatable, Sendable { case text, binary, unknown }
    /// By name only; never touches the disk.
    public static func classify(_ url: URL) -> Classification
    /// By the first bytes of the file (call with up to 8 KB).
    public static func looksBinary(_ head: Data) -> Bool
    /// A short human label from magic numbers ("Mach-O 64-bit", "ZIP archive", ...), nil if unknown.
    public static func describe(_ head: Data) -> String?
}
```

- `classify(_:)`:
  1. `LanguageIdentifier.identifier(for:)` non-nil, or `UTType` conforming to `.text`, `.sourceCode`, `.json`, `.xml`, `.propertyList` → `.text`. (Check the language registry first: it knows `Makefile`, `Dockerfile`, dotfiles.)
  2. `UTType` conforming to `.executable`, `.archive`, `.audiovisualContent`, `.pdf`, `.font`, `.database`, `.diskImage`, `.bundle`, or in a small extension table (`class`, `jar`, `o`, `a`, `dylib`, `so`, `wasm`, `bin`, `dat`, `db`, `sqlite`, `ttf`, `otf`, `woff`, `woff2`) → `.binary`.
  3. Otherwise `.unknown`, which means "sniff".
  Images are handled before this and stay in the image viewer.
- `looksBinary(_:)`, applied to the head for `.unknown` files:
  - Empty → text.
  - BOM-marked UTF-8 / UTF-16 / UTF-32 → text (reuse `TextFileEncoding.detect(byteOrderMarkIn:)`).
  - Known magic (`describe` ≠ nil and the format is binary: ELF `7F 45 4C 46`, Mach-O `FEEDFACE/FEEDFACF/CAFEBABE/CFFAEDFE`, PE `MZ`, ZIP `PK 03 04`, gzip `1F 8B`, PNG, PDF `%PDF`, SQLite `SQLite format 3\0`, WASM `00 61 73 6D`, class files `CAFEBABE`) → binary. `%PDF` is text-looking but binary in practice, so the table wins over the byte statistics.
  - A NUL byte in the head → binary, **unless** `TextFileEncoding.guess` returns UTF-16 (alternating zeros), which is text.
  - Otherwise valid UTF-8, or `guess` non-nil with at most ~1 % control bytes outside `\t \n \r \f \e` → text. Anything else → binary.
- Cost: one 8 KB `pread` per open of an unknown-type file; no scan of the file.

Tests (`Tests/PenumbraTests/BinaryContentDetectorTests.swift`): each magic number; a UTF-16 LE file with and without BOM stays text; a Latin-1 file stays text; UTF-8 with a NUL is binary for `.unknown` and text for `.swift`; `LICENSE`, `Makefile` and `.gitignore` are text; an empty file is text; every extension in the table; truncated heads (1–3 bytes).

## 2. Document kind and routing

### Penumbra
- `WorkbenchDocumentContentKind` (`WorkbenchDocument.swift:6`) gets `case binary` (doc: "A host-drawn hex view of a file's bytes").
- `WorkbenchDocument.loadBinary(from:)`, the twin of `loadImage(from:)` (:160): url and display name, empty text, `contentKind = .binary`.
- `EditorRestorationState.swift`: `.binary` is restored with the session (unlike `.diff` / `.diagram`, :163), because it is a file tab. Decoding `contentKind` is made tolerant (unknown raw value → `.text`) so a session written by this build does not fail to load in an older one.

### Umbra
- `loadDocument(from:encoding:preferring:)`:
  1. image check (unchanged);
  2. `BinaryContentDetector.classify(url)`: `.binary` → `loadBinary`; `.unknown` → read the 8 KB head, `looksBinary` → `loadBinary`;
  3. text load as today; if every attempt ends in `DocumentLoadError.invalidEncoding` and no `encoding:` was requested → `loadBinary` instead of throwing.
- A new `openAsHex: Bool` / `openAsText: Bool` pair of parameters lets "Reopen as Hex" and "Reopen as Text" bypass the detector.
- Session restore: a restored `.binary` snapshot goes through `loadBinary` and rebuilds its session lazily when the tab is first shown, like text tabs.
- Every `contentKind` check that currently reads `!= .diff && != .diagram` must become `== .text` (a `.binary` document is not editable text and must not feed the agent, the language services or Markdown run). Known sites: `Agent/IDEAgentEntryPoints.swift:93`, `Agent/IDEWorkspace+Agent.swift:132`. Audit with `grep -rn "contentKind" Example/Umbra Sources`.

## 3. `HexKit` (new library, no dependencies)
`Sources/HexKit/`, declared in the root `Package.swift` like `JavaIntelligence` (`swift6`, no `Penumbra`, no AppKit). Tests in `Tests/PenumbraTests/HexKit*Tests.swift` (the target that already holds Umbra's tests). `Sources/HexKit/CLAUDE.md` is added with the same contents as this section.

| File | Responsibility |
|---|---|
| `HexByteSource.swift` | `protocol HexByteSource: Sendable { var count: Int64 { get }; func read(_ range: Range<Int64>, into: UnsafeMutableRawBufferPointer) throws -> Int }`. |
| `FileByteSource.swift` | `pread` on a read-only file descriptor with a page cache: 64 KB pages, LRU of 256 (16 MB cap), readahead of one page in the scroll direction. `invalidate()` drops pages; `refreshSize()` re-`fstat`s. A short read (file truncated underneath) zero-fills and sets `isStale`. |
| `HexDocument.swift` | Piece table: `[Piece]` of `(source: .original/.added, offset, length)` plus cumulative offsets for binary search. `byte(at:)`, `read(range:)`, `overwrite(at:bytes:)`, `insert(at:bytes:)`, `delete(range:)`, `count`, `isModified`, `modifiedRanges` (for highlighting). Pieces merge when adjacent and contiguous; compaction into a fresh added buffer past 4,096 pieces. |
| `HexUndoStack.swift` | Commands (`overwrite`, `insert`, `delete`) with coalescing: consecutive typed bytes within 500 ms and adjacent offsets are one undo step. Bounded (1,000 steps; the oldest are folded into the base so memory stays flat). |
| `HexSearch.swift` | `HexPattern` (bytes + optional per-byte mask for `??` wildcards), `search(in:from:direction:limit:)` as an `AsyncSequence` of `Range<Int64>`. Chunked reads of 1 MB with `pattern.count - 1` overlap, `memchr` on the rarest byte of the pattern then compare, cooperative cancellation every chunk. Text input is encoded as ASCII, UTF-8, UTF-16 LE/BE or Latin-1 (selectable), optionally ASCII case-insensitive. |
| `HexWriter.swift` | Streams `HexDocument` pieces to a temp file in the destination directory and renames over the target, preserving mode, with the same strategy as `DocumentWriter` (`DocumentWriter.swift` ~:298). Progress callback; cancellable; throws before touching the target on error. Refuses (with a typed error) when the file's size or mtime changed since it was opened, unless told to overwrite. |
| `HexFormatting.swift` | Row layout (`bytesPerRow`, `groupSize`), offset formatting (hex/decimal, width from file size), text-pane decoding per byte for ASCII, Latin-1, Mac Roman, CP437, Windows-1252 (control and non-printing bytes show `·`). |
| `HexInspector.swift` | Interprets up to 16 bytes at an offset: `Int8…Int64` and `UInt8…UInt64` in both byte orders, `Float`/`Double`, binary, ASCII/UTF-8 scalar, Unix time (s and ms), Mac absolute time, `UUID`, with "not enough bytes" per row. Pure. |
| `HexFormatDescriber.swift` | Wraps `BinaryContentDetector.describe` and, for a few formats, reads one header field (Mach-O architecture, ELF class and machine, ZIP entry count). Optional; see Phase 4. |
| `HexCopyFormats.swift` | Selection → hex string (`4D 5A 90`), plain `0x` list, C array, Base64, ASCII text, `hexdump -C` block, Swift `[UInt8]` literal. And the reverse for paste: hex digits with any separators, `0x` prefixes, or plain text. |

Concurrency: `HexDocument` is a struct owned by one `@MainActor` session; searches and saves take a value snapshot (`HexDocument` copy-on-write pieces array + `Sendable` byte source), so they never read the live document from a background task.

Tests:
- `FileByteSourceTests`: reads at page boundaries, past EOF, an empty file, a file truncated mid-read, concurrent reads, LRU bound.
- `HexDocumentTests`: overwrite/insert/delete at start, middle, end and across piece boundaries; length bookkeeping; a randomized differential test against a plain `[UInt8]` model (10,000 operations, seeded).
- `HexUndoStackTests`: undo/redo equivalence with the differential model; coalescing; the bound.
- `HexSearchTests`: pattern spanning a chunk boundary, wildcards, overlapping matches, backwards, cancellation, case-insensitive ASCII, UTF-16.
- `HexWriterTests`: round trip with and without edits, mode preserved, target untouched on failure, changed-on-disk refusal, a 64 MB sparse file.
- `HexInspectorTests`, `HexCopyFormatsTests` (including the paste parser's edge cases).

## 4. The view (`Example/Umbra/HexEditor/`)

| File | Role |
|---|---|
| `IDEHexSession.swift` | `@MainActor @Observable`: the `HexDocument`, selection, mode, find state, scroll position and settings snapshot for one tab. Lives in `IDEWorkspace.hexSessions[documentID]`, `@ObservationIgnored`, like `diffSessions` and `diagramSessions`. Two panes showing one file share it. |
| `IDEHexCanvasView.swift` | The AppKit view. Custom drawing, `topRow: Int64`, viewport-sized. Hit testing, keyboard, mouse, drag-select, drag auto-scroll, first responder. |
| `IDEHexRootView.swift` | SwiftUI composition inside an `NSHostingView`: toolbar row, canvas (`NSViewRepresentable`), data inspector and find bar. The inspector split is a `SplitPanes` (no `NSSplitView`/`HSplitView`, per `Example/Umbra/CLAUDE.md`). |
| `IDEHexViewerView.swift` | The `NSView` the pane host lays over its editor, with `show()`/`hide()`/`focus()`, exactly the shape of `IDEDiagramViewerView`. |
| `IDEHexInspectorView.swift`, `IDEHexFindBar.swift`, `IDEHexGoToOffsetSheet.swift` | The pieces named. |
| `IDEHexModule.swift` | A chrome-only `IDELanguageModule` (like `IDECSVModule` in `Languages/IDEPreviewModules.swift`): status items, toolbar items, View menu entries, palette commands, a Settings page. Listed in `IDELanguageModules.shipped`. |
| `IDEWorkspace+Hex.swift` | `showHexDocument`, open/close/save/reopen glue, external-change handling. |

### Layout
```
 offset      00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F   text
 00000000    7F 45 4C 46 02 01 01 00  00 00 00 00 00 00 00 00   .ELF............
 00000010    03 00 3E 00 01 00 00 00  40 10 00 00 00 00 00 00   ..>.....@.......
```
- Columns: offset, hex bytes grouped by `groupSize` (1/2/4/8, default 8 as above), text pane. A header row with column indices; the row under the caret and the byte's counterpart in the other pane are tinted.
- `bytesPerRow`: Auto (fit the width in multiples of 8, minimum 8, maximum 64), or a fixed 8/16/24/32/48/64.
- Font is the editor font from `IDEEditorTheme`, scaled by session zoom; colors come from the theme and `IDEAppearance` tokens (NUL bytes dimmed, printable ASCII normal, whitespace and control bytes in distinct tints, ≥ 0x80 in a fourth; a "Color Bytes by Class" switch, on by default).
- Modified bytes (from `modifiedRanges`) are drawn in the accent color; search matches get the existing find-highlight colors.
- The drawing path reads `rows × bytesPerRow` bytes of the viewport from the document into a reused buffer, builds one attributed string per row (cached by row and document generation, bounded to the visible rows plus a margin), and draws. No per-frame allocation of the whole file, no `Data(contentsOf:)`.
- Scroller: a legacy-or-overlay `NSScroller` driven by `topRow / lastRow` (`knobProportion = visibleRows / totalRows`). Trackpad and wheel deltas are accumulated in points and converted to rows; a drag on the knob maps linearly, so a 4 GB file seeks in one gesture. Page Up/Down, Home/End, ⌘↑/⌘↓ and ⌃G (go to offset).

### Input
- **Selection:** a byte range with an anchor, plus which pane has focus and a nibble (high/low) for the caret in the hex pane. Click, ⇧-click, drag, double-click (selects the aligned group), ⌘A, arrows (left/right by byte, up/down by row), ⇧ to extend, ⌥←/→ by 4/8 bytes per `groupSize`.
- **Typing in the hex pane:** `0-9 a-f A-F` write nibbles in overwrite mode (two keystrokes complete a byte, the caret advances); in insert mode the first nibble inserts a `0x?0` byte. Invalid keys beep. **In the text pane:** a typed character is encoded with the pane's encoding and written; a character with no single-byte form beeps.
- **Delete / ⌫:** in insert mode removes the selection or the byte; in overwrite mode ⌫ moves back one byte and ⌦ does nothing (consistent with fixed length), with **Edit ▸ Fill Selection…** and **Zero Selection** for in-place changes.
- **Clipboard:** ⌘C copies per the "Copy As" default (hex), ⌥⌘C/the context menu offer `HexCopyFormats`; ⌘V parses hex or text; in overwrite mode a paste longer than the file's remaining bytes asks whether to extend, truncate or cancel.
- **Undo/redo:** ⌘Z / ⇧⌘Z through the session's own stack, not `NSUndoManager`'s text stack; the stack is cleared when the file is reopened from disk.
- **Find:** ⌘F opens the bar (mode: Hex / Text; encoding; case; wildcard `??`), ⌘G / ⇧⌘G next/previous with wrap and "N of M" while the count is bounded (stop counting at 100,000 and say "100,000+"), Esc closes. Searches run off the main actor and are cancelled by a new query, an edit or closing the bar. Replace (overwrite same length, or insert) arrives in Phase 3.
- **Go to Offset:** ⌘L / the Go to Line shortcut when a hex tab is active (`goToLine` is routed by document kind): `0x1F40`, `8000`, `+0x20` / `-16` relative to the caret, `end`.
- **Context menu:** Copy As ▸, Paste, Select All, Go to Offset…, Show Data Inspector, Bytes per Row ▸, Text Encoding ▸, Reopen as Text, Reveal in Finder.

### Data inspector (right pane, toggle ⌥⌘I)
Table from `HexInspector` for the bytes at the caret (or the first 8 of the selection): integers signed/unsigned, float/double, little/big endian switch, character, Unix time, UUID. Double-click a row copies its value. When the selection is longer than 8 bytes it also shows length, a decimal and hex count, and **Hash** (MD5/SHA-1/SHA-256, computed off the main actor on demand, reusing `IDEHashText`'s digests).

### Status bar and chrome
- `IDEWorkspace.updateStatus` (~:5348) treats `.binary` like the other non-text kinds but sets `statusLanguage = "Hex"`; the module contributes status items: `Offset 0x1A2F (6703)`, `Sel 16 B`, `OVR`/`INS` (click toggles), and the text-pane encoding (the existing encoding picker's slot, bound to the session).
- The tab shows the dirty dot from `WorkbenchDocument.isDirty` as for text. The tab context menu (`IDEEditorTabsBar.swift` ~:85) gets **Reopen as Hex** (text tabs) and **Reopen as Text** (hex tabs); **Reload from Disk** is offered for `.binary` too.
- A text document's right-click menu, View menu and palette get **Open as Hex Editor** (`hex.openAsHex`).

### Integration points (checklist; line numbers approximate)
| Site | Change |
|---|---|
| `IDEWorkspace.showDocument(in:host:)` ~:5600 | Add `.binary` branch: hide the diff and diagram viewers and the image viewer, `showHexDocument`; the existing branches also call `host.hexViewer.hide()`. |
| `showImageDocument` / `showDiffDocument` / `showDiagramDocument` / text path | Hide the hex viewer; flush text state first as they already do. |
| `IDEWorkspace.selectTab` focus switch ~:4107 | `.binary` → `host.hexViewer.focus()`. |
| `saveActiveDocument()` ~:1194 | `.binary` → `saveHexDocument` (`HexWriter`; Save As via the panel when untitled, which a hex tab never is). |
| Quit and close prompts ~:2349, ~:3013 and the tab close path | Include dirty `.binary` documents; the prompt names the file and the byte count changed. Today they filter `contentKind == .text`. |
| `reloadTabFromDisk` ~:3556 | `.binary`: confirm if dirty, reopen the source and clear the stack. |
| `IDEProjectWatcher` events for an open file | Clean hex session: invalidate the cache and refresh size, keep `topRow` and selection clamped. Dirty: banner "Changed on disk" with **Reload** / **Keep Mine** / **Compare** (Compare is Phase 4). |
| `IDEWorkspace.teardown()` | Cancel searches and saves, close file descriptors (a hex session holds one per open tab). |
| `workspaceBridge.syncWorkbench`, `localHistory.recordBaseline`, agent mentions, language services | Already `contentKind == .text` gated; confirm with the audit above. |
| Explorer and Go to File | No change: they open through `openDocument`, which now routes. The file tree's icon for a binary file may use the same generic document symbol. |
| Info.plist `CFBundleDocumentTypes` | Add `public.data` with `LSHandlerRank` `Alternate`, so Finder's Open With lists Umbra for any file. Never `Default`, so Umbra does not steal other apps' files. |

## 5. Settings (`IDEPreferences`, Settings ▸ Editor ▸ Hex)
Kept on this Mac, outside the preferences snapshot, as the sticky-lines and code-insight settings are.

- Open Binary Files in Hex Editor (default on). Off restores the old behaviour: error alert for undecodable files.
- Open Unknown Files by Content (default on). Off: only known binary types open as hex.
- Extensions to always open as text / as hex (two lists, e.g. a `.dat` that is text). Consulted before `classify`.
- Bytes per row, group size, offset base, uppercase digits, color bytes by class, default text encoding, default Copy As, data inspector visible and endianness.
- Large-file warning threshold for editing (default 256 MB): above it the view opens read-only and **Make Editable** asks first, because a long insert on a piece table is cheap but a save rewrites the whole file.

## 6. Performance
This is a new hot path (scroll and typing) and follows `docs/PERFORMANCE_RULES.md`: work per frame or keystroke is bounded by visible rows or edit size, never by file size.

| Path | Budget (Release) |
|---|---|
| Open any file in hex | < 50 ms to first paint, independent of size (no scan, one 8 KB sniff + one page read) |
| Scroll frame | < 4 ms at 120×64 visible bytes |
| Seek (scroller drag, go to offset) | < 16 ms, no spinner |
| Keystroke edit (overwrite/insert) | < 1 ms, flat with file size and with up to 4,096 pieces |
| Search throughput | ≥ 500 MB/s single pattern on a 1 GB file; first match within one 1 MB chunk |
| Resident memory | page cache 16 MB + pieces + added buffer; never proportional to file size |

Measured in Release with `swift run -c release PerfHarness hex-scroll` and `hex-search` on a 4,294,967,296-byte sparse file. Both runs found the seeded pattern at offset 4096, kept 4,096 pieces, and stayed inside the page cache (6 cached pages).

| | hex-scroll | hex-search | Budget |
|---|---:|---:|---|
| Open | 0.203 ms | 0.044 ms | < 50 ms |
| Scroll frame (120×64) | 0.170 ms | 0.088 ms | < 4 ms |
| Seek | 0.019 ms | 0.012 ms | < 16 ms |
| Keystroke at 4,096 pieces | 8.208 µs | 9.791 µs | < 1 ms |
| Search | 17187.744 MB/s | 18581.878 MB/s | ≥ 500 MB/s |

- Add `PerfHarness hex-scroll` and `hex-search` (`Tools/PerfHarness`): create a sparse N GB file (`ftruncate`) with seeded patterns, then report open, scroll-step and search timings. Measure on the parent commit and on the change, in Release (`swift run -c release PerfHarness hex-scroll --size 4gb`), as the root CLAUDE.md requires.
- `HexDocumentTests` includes a count of source reads per `read(range:)` so an edit does not re-read the file.

## 7. Phases
Each phase ends with `swift build`, the new test files, and the existing suite (`caffeinate -u -d -i -s swift test`), and is a reviewable commit.

1. **Detection and a read-only hex view.** `BinaryContentDetector`, `.binary` kind, `HexKit` byte source and formatting, canvas with virtual scroll, status items, routing in `loadDocument`, session restore, `Reopen as Text/Hex`, the `contentKind` audit. Exit: opening a Mach-O, a `.class`, a PNG renamed to `.dat`, and an extension-less binary shows hex; a Swift file and `LICENSE` still open as text; a 2 GB sparse file opens instantly and scrolls smoothly.
2. **Selection, clipboard, inspector, Go to Offset, search.** `HexSearch`, `HexInspector`, `HexCopyFormats`, find bar, inspector pane, context menu.
3. **Editing and saving.** `HexDocument` piece table, undo stack, typing in both panes, insert/overwrite, fill/zero, `HexWriter`, dirty/save/close/quit prompts, external-change banner, find and replace, large-file read-only gate.
4. **Polish.** Settings page, accessibility, format descriptions, bookmarks (bounded per file, saved in the session), Compare with Disk (a read-only side-by-side of changed ranges), the performance harness numbers recorded in this doc, and `Example/Umbra/CLAUDE.md` / `Sources/HexKit/CLAUDE.md` / root `CLAUDE.md` updates.

## 8. Tests in Umbra (`Tests/PenumbraTests`, `@testable import Umbra`)
- `IDEHexRoutingTests`: `openDocument` of a binary fixture yields `.binary`; a UTF-8 file with a NUL under an unknown extension yields `.binary`; `.swift` with NULs stays `.text`; an undecodable `.txt` falls back to `.binary` but "Reopen with Encoding" still reports the encoding error; Reopen as Text/Hex round-trips with and without unsaved changes.
- `IDEHexSessionTests`: selection and nibble state machine, overwrite versus insert, undo/redo, mode toggle, modified ranges, dirty flag against `WorkbenchDocument.isDirty`.
- `IDEHexViewTests`: hosts the canvas in a window like `IDEAgentComposerFieldTests`: row math for sizes 0, 1, 15, 16, 17, `Int32.max + 1`; hit testing; scroller mapping at 4 GB; drawing a frame does not read outside the viewport (count reads through a recording `HexByteSource`).
- `IDEHexSessionRestoreTests`: a `.binary` tab survives a session round trip with scroll and selection; an older-format file with no `contentKind` decodes.
- `IDEHexWorkspaceTests`: save writes bytes and keeps the mode; quit prompt includes a dirty hex tab; an external change refreshes a clean session and raises the banner for a dirty one; closing the window leaves no file descriptors open and nothing retaining the workspace (the retention pattern in `IDEProjectAndRunProviderTests`). A test that makes a workspace sets `IDEWorkspace.isSessionPersistenceEnabled = false`.
- `IDEHexModuleTests`: toolbar, status and menu contributions appear only for a hex tab (the pattern in `IDEModuleContributionTests`).

## 9. App Store and sandbox
- Only public API: `open`/`pread`/`fstat`/`rename`, `UTType`, AppKit drawing. No `Process`, no private SPI, nothing loaded dynamically.
- File access is whatever the user granted through the open panel, drag and drop or the project folder (`IDESecurityScopedAccess`); the writer's same-directory temp file needs the same access the text writer already requires, and the failure path is the same (error alert, target untouched).
- No network, no telemetry, no background activity: searches and saves are user-initiated and cancellable.
- Hash and describe use CryptoKit and bundled magic tables; nothing leaves the Mac.

## 10. Risks and open points
- **Misclassification.** The heuristic can send a text file to hex (a CSV in UTF-16 with no BOM and few zero bytes) or a binary to text. Mitigations: the explicit lists in Settings, "Reopen as …" on every tab, and a one-line banner above a content-sniffed hex tab ("Opened as hex: this file does not look like text. Open as Text"), dismissible and remembered per file.
- **Large insertions.** Insert mode into a 10 GB file is cheap in the editor and expensive on save (a full rewrite). The save shows progress, is cancellable, and the large-file gate warns.
- **Concurrent writers.** A `pread` view of a file another program is rewriting can show a torn state; the size/mtime check on save is the only protection. Same as any editor without file locking.
- **Descriptors.** One fd per open hex tab. Tabs far from use can close theirs and reopen on demand if this shows up (cap at 64 open sources).
- **Text pane encodings** other than the single-byte ones (UTF-8 multi-byte display across byte cells) are out of scope; the pane shows one glyph per byte.
- **Open question for the owner:** whether a file under a known text extension that is NUL-heavy should prompt instead of staying text. The plan keeps it text and relies on Reopen as Hex.

## 11. Out of scope
Binary templates (010-Editor style structure parsing), disassembly, diff of two arbitrary binaries (only Compare with Disk), editing block devices or process memory, checksum/CRC tools beyond the inspector hashes, bit-level editing, and a hex view of an image's decoded pixels.
