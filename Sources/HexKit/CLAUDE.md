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
