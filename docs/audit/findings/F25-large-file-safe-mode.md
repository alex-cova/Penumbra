# F25 — No large-file safe mode

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** B
- **Status:** ✅ Done (2026-11-04) — policy, engine switches, index-skip report, Umbra banner, Enable Anyway and the oversized-files notice; 520 MB open measured · **Owner:** Unassigned

## Evidence

- Mitigations that exist: mmap-backed piece tree, viewport parse (262,144 UTF-16 window past 1M units), line-controller eviction, 256 KB prefetch. Doc figures (partly stale, pre-mmap-fix): 10 MB open 37 ms / 52 MB RSS, 100 MB 253 ms / 109 MB, 500 MB 5.25 s / 1.42 GB, 2 GB 24.3 s / 4.81 GB.
- `LargeFileOpenTests` covers only a fold-scan guard. There is no size threshold that degrades gracefully — highlighting, folding, indexing, and intelligence all attempt full service until they individually time out or cap.
- Files over 1 MiB are silently skipped by Swift/TypeScript indexing (`maxBytes = 1_048_576`) with no user-visible signal — the same silent-degradation pattern.

## Root cause

Large-file behaviour is emergent from per-feature caps, never designed as a mode.

## Fix sketch

Define thresholds (prompt / degrade / read-only tiers, Sublime-style): above tier 1, disable tree-sitter highlighting + folding + indexing with a visible banner and one-click "enable anyway"; above tier 2, read-only. Surface the existing silent 1 MiB index skip in the same UI language.

## Complexity / Dependencies

M. Re-measure the stale 500 MB/2 GB figures first (F06 infrastructure).

## Acceptance criteria

- Opening a 500 MB file reaches an editable (or explicitly read-only) view within an agreed budget, with the degraded features named in the UI.

## Tests / benchmarks

- LargeFileOpenTests extended to the mode thresholds; PerfHarness open scenario at 100/500 MB.

## Out of scope

Streaming editors for multi-GB files beyond the read-only tier.

## Implementation notes (2026-11-04)

**Decided (with the user).** Tiers: 50 MB degrades, 500 MB is read-only (`LargeFilePolicy.standard`; the doc's 100 MB open is ~250 ms, so degrading earlier would cost features for no gain). The Umbra banner is a follow-up because the Umbra package could not be compiled on this machine (Metal Toolchain missing for `mlx-swift`).

**Done in the libraries.**
- `LargeFilePolicy` (`Workbench/LargeFilePolicy.swift`): `Tier` (`normal`, `degraded`, `readOnly`), `Feature` names for the banner, `standard` / `disabled`, `tier(forByteCount:)`. `LargeFileNotice` carries the tier, the size and a one-line `message` ("Large file (120 MB): syntax highlighting, code folding and indexing and code intelligence are off.").
- `WorkbenchDocument.load(…, largeFilePolicy:)`: a file over the degrade size opens with no tree-sitter language (no parse, highlight queries or fold scan; `languageIdentifier` is kept) and sets `largeFileNotice`. **The default is `.disabled`**: a host opts in with `.standard` when it can show the notice, so nothing degrades silently. "Enable anyway" is a reload with `.disabled`.
- `TextView.largeFileTier`: above `.normal` folding stays off and, at `.readOnly`, `isEditable` stays false, whatever the host sets afterwards (Umbra's `preferences.apply(to:)` runs after `setState`); back to `.normal` restores what the host last asked for.
- Index skip made visible: `SourceFileIndex.enumerateReportingOversized`, and `SwiftIndex.oversizedFiles` / `TypeScriptIndex.oversizedFiles` list the source files a walk left out for being over `maxBytes` (1 MiB). Cleared with the root.
- Tests (`LargeFileModeTests`, 9): tiers, notice text, degraded/read-only/enable-anyway loads, a real 52 MB file under `.standard`, the `TextView` tier round trip, the Swift index's oversized list.

**Done in Umbra (follow-up, built and tested once the Metal Toolchain was installed).**
- `loadTextDocument` opens under `IDEWorkspace.largeFilePolicy(for:)` (`largeFileBasePolicy` = `.standard`; a path in `liftedLargeFilePaths` gets `.disabled`) and keeps a degraded file's language nil. `installReloaded` carries the notice across a reload, either way.
- `showDocument` sets `host.textView.largeFileTier` right after `setState`, before preferences and editability are applied (the tier overrides both), and gives the text view, the workspace bridge (`makeEIPDocument`), semantic highlighting and line markers `WorkbenchDocument.intelligenceLanguageIdentifier`, which is nil for a degraded file: no language services, no indexing of it, no semantic colours. The status bar still shows the real language.
- `IDELargeFileBanner` (above the external-change banner in `IDEEditorPaneView`): the notice's message, and **Enable Anyway** (disabled with a tooltip while the tab has unsaved edits, because the reload would drop them). `enableLargeFileFeatures(for:)` adds the path to `liftedLargeFilePaths`, reloads, and resyncs the bridge; lasts for the window's session.
- `IDESwiftSupport` / `IDETypeScriptSupport.onOversizedFiles` → `IDEWorkspace.noteOversizedSourceFiles`: one notification per set ("2 Swift files over 1 MB not indexed", with names), so the silent 1 MiB skip is visible.
- Tests (`LargeFileModeUmbraTests`, 5, with the 50 MB tier lowered to 1 MB through `largeFileBasePolicy` so files stay small): open degraded, Enable Anyway, unsaved edits block it, read-only holds in the window, the notice posts once.

**Measured (release, `PerfHarness open <file> --mmap`, plain, 520 MB):** 1.83 s to load, 331 MB resident (the stale doc figure for 500 MB was 5.25 s and 1.42 GB, highlighted). A debug `swift test` run of the whole open path (load, `setState`, layout) took 24 s with the same RSS; `swift test -c release` does not build today because some tests use DEBUG-only helpers (`lineManagerForTesting`), so the full-path release number is not recorded. `LARGE_FILE_MEASURE_MB=520 swift test --filter LargeFileModeTests/testMeasureOpen` reproduces the debug one.

**Not done / decided.**
- No user setting for the tiers or to turn the mode off (`largeFileBasePolicy` is code-only); a Settings ▸ Editor switch would be the next step if the thresholds need tuning.
- The minimap is not tier-aware in the engine.
- Hex-sniffed and hex-forced files are unaffected (they never reach this path).
- Opening a degraded file still builds its line index and a full piece tree: that is the 1.8 s above and is the floor of this design (streaming editors for multi-GB files are out of scope).
