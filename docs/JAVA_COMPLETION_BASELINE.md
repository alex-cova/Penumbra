# Java completion: measured baseline

Recorded numbers for `JavaCompletionProvider`, so a change is judged against a measurement and
not an estimate. Replaces the `docs/JAVA_COMPLETION_PLAN.md` that the code used to cite and that
never existed. Corpus score: `docs/JAVA_PARITY.md`; external accuracy: `docs/JAVA_DIFFERENTIAL.md`.

Release build, `swift run -c release PerfHarness java-completion synthetic [--jars N]`, JDK 26,
display awake, 12 samples per site after two warm-up runs. The harness times the provider only
(not the editor, controller or popup): a keystroke-to-popup measurement does not exist yet.
Numbers are from one machine and one session; day-to-day drift of up to 2x is documented in
`docs/PERFORMANCE_RULES.md` §9, so compare a change against its parent commit in the same session
(`Scripts/perf-gate.py`), not against this file.

## Where a keystroke goes (5,000-line file, member access)

`JavaCompletionStageTimer` (`@_spi(Benchmarks)`) splits a request into stages; the harness prints
`detail` rows with each stage's mean and its share of the median request.

| stage | before | after | note |
|---|---|---|---|
| `repair` (`repairedText`) | 7.7 ms (68%) | 0.19 ms (5%) | `isInsideMethodBody` iterated `Character`s of a copy of the whole prefix, and the rest-of-line check copied the document tail |
| `parse` (incremental) | 0.76 ms | 0.75 ms | tree-sitter reparse of the edit; a cold full parse is 8.4 ms |
| `stubs` | 2.7 ms | 2.7 ms | `JavaSourceStubBuilder.build` over the whole tree; proportional to the members the file declares (it already skips method bodies) |
| `receiver`, `members`, `classify`, offsets, bytes | < 0.15 ms together | | |
| **median request, typing** | **11.4 ms** | **3.9 ms** | `member_access_typing` |
| median request, fresh provider | 19.0 ms | 11.6 ms | `member_access`, includes the 8.4 ms cold parse |

Small file (a few lines): 0.2 ms for member access. The 5,000-line file therefore still costs
about 16x the small one while typing; what is left is the stub rebuild.

## First update vs final update (200 synthetic JAR shards, 86k names)

Before the fast result was published early, "first" and "final" were the same instant for every
site. After:

| site | first | final |
|---|---|---|
| class name, 1 char | 0.77 ms | 5.9 ms |
| class name, 3 chars | 0.64 ms | 3.2 ms |
| class name, 7 chars | 0.62 ms | 3.8 ms |
| `new` with expected type | 5.6 ms | 5.6 ms (the leading implementation is chosen over both phases, so it cannot be split) |

Provider time is small on a synthetic index. The slow phase matters more with a real classpath;
measure it on gson, jackson-core and the Gradle project before claiming a user-visible gain.

## Stub reuse (`JavaStubReuse`)

The `stubs` stage rebuilt every stub of the file on each request. An edit strictly inside one
method or constructor body cannot change them (the builder never reads bodies and local classes
are not stubs), so the previous stubs are moved past the edit instead (`Syntax/JavaStubReuse.swift`).
Anything else, and any file with a syntax error outside the edited body, rebuilds as before.
`UMBRA_JAVA_STUB_REUSE=0` turns reuse off. `PerfHarness java-stub-reuse synthetic` and
`java-completion synthetic --large-methods N` (N = lines / 5) measure it.

| file | stub stage, rebuilt | stub stage, reused | typing request, reuse off | typing request, reuse on |
|---|---|---|---|---|
| 5,000 lines | 4.2 ms | 0.009 ms | 3.83 ms | 1.17 ms |
| 20,000 lines | 17.0 ms | 0.011 ms | 15.0 ms | 3.94 ms |
| 120,000 lines | 103.5 ms | 0.021 ms | 94.6 ms | 25.2 ms |

A structural edit (a renamed method) rebuilds in the same time as before (4.16 ms against a
4.16 ms rebuild at 5,000 lines): the checks that decide to fall back cost nothing measurable.
Fifty successive stub sets for a 20,000-line file hold 11.5 KB when moved and 56.9 MB when each
is rebuilt (the editor keeps one set, so the practical gain is allocation churn: about 1.1 MB per
keystroke at that size).

What is left per typing request is the incremental parse (65-80%), which still grows with the
file: `ParseEdit.diff` compares and scans both texts and computes three row/column points from
byte 0. That is the next cost to attack.

## Reparse after an edit (`ParseEdit.diff`, `repairedText`)

`PerfHarness java-parse-edit synthetic [--per-class N]` times each piece of "previous tree to this
text" on one persistent parser with successive edits (the editor's protocol; a fresh parser per
measurement is 2x slower and misleading). Release, medians of 15, milliseconds. A typed character
in the middle of the file; the other edit kinds (a 12-line insert, a deleted method, the start and
the end of the file) are within a few percent of it.

**What the cost was.** `ParseEdit.diff` compared and scanned both texts with Swift byte loops, then
computed three row/column points each from byte zero:

| 120,000 lines | prefix + suffix scan | three points | `diff` total |
|---|---|---|---|
| before | 1.35 | 2.31 | 3.7 |
| after | 0.10 (blocked `memcmp`) | 0.06 (one start point, 8 bytes per step) | 0.17 |

The prefix is common to both texts, so one count over it gives the start point, and the old and new
end points are that point advanced over the changed bytes only. The newline count was the only
part that read the whole prefix, and a one-byte-at-a-time loop ran at 1.3 GB/s (the compiler did
not vectorize it); the 8-byte count runs at about 22 GB/s (the blocked `memcmp` scans, about 30 GB/s).

| file | `diff` before | `diff` after |
|---|---|---|
| 5,000 lines | 0.15 | 0.010 |
| 20,000 lines | 0.61 | 0.030 |
| 120,000 lines | 3.7 | 0.17 |

Edits at the start of the file are cheaper still (nothing to count) and at the very end cost the
most (the whole file is prefix): 0.21 ms at 120,000 lines.

**What the cost was not.** The share of the parse stage that is the diff depends on how the code is
shaped, because tree-sitter's own incremental parse costs by the *arity* of the nodes on the edit
path, not by lines. One class holding 24,000 methods (what the harness's large file used to be)
costs 16-17 ms per edit anywhere but the start of the file; the same 120,000 lines in nested
classes of 100 methods cost 0.3 ms. A real 5,000-line file has hundreds of members, not thousands.

| 120,000 lines | tree-sitter incremental parse | `diff` before | `diff` after |
|---|---|---|---|
| one class, 24,000 members | 16.3 | 3.7 | 0.17 |
| nested classes, 100 members each | 0.31 | 3.7 | 0.17 |

For the first shape tree-sitter is 82-98% of the parse stage whatever is done here; for the second
the diff was 92% of it. `copy` + `apply` the edit is 0.003-0.01 ms in both.

**`repairedText`.** `isInsideMethodBody` was 3.4 of its 3.85 ms at 120,000 lines: it transcoded the
text before the caret to UTF-16 and tested every unit, to answer a question that depends only on
the braces. It now scans the UTF-8 bytes for `{` and `}`, eight at a time, and looks back for the
previous significant character only at an opening brace: 3.85 to about 0.9 ms (the rest is the
copy that builds the repaired text).

**Typing completion request, provider only (nested classes of 100 methods).** Before is the
original `diff` and the original brace scan; after has both new; the stub reuse above is in both.

| file | before | after | `repair` | `parse` stage |
|---|---|---|---|---|
| 5,000 lines | 0.645 ms | 0.294 ms | 0.19 to 0.08 | 0.27 to 0.03 |
| 20,000 lines | 1.869 ms | 0.439 ms | 0.63 to 0.16 | 1.02 to 0.08 |
| 120,000 lines | 10.58 ms | 1.933 ms | 3.80 to 0.93 | 6.19 to 0.42 |

One class of 24,000 methods, 120,000 lines: 25.2 ms (stub reuse only) to 16.7 ms, 87% of it
tree-sitter. These are provider times, not the time to a visible popup.

**What is left per request at 120,000 lines (nested):** `repairedText` 0.93 ms (48%), the parse stage
0.42 ms (22%), the rest receiver typing and bookkeeping. Still proportional to the file: building
the repaired text (copies of the text before and after the caret), the brace count over the
prefix, and the copies of the new text as bytes (three per request: `reparse`, `parseIncremental`
and the request's own `bytes`, about 0.15 ms together at this size). In the editor
`JavaNavigationText.fullText` also materializes the document for a file-backed buffer, which this
harness does not exercise.

**Not done, and why.** Passing the editor's own edit to the parser would remove the comparison but
not the other whole-text work above, and the comparison is now 0.17 ms at the largest size; the
completion provider only receives snapshots, so it would mean carrying edits through
`CompletionContext` for every language. A persistent line index would save the 0.06 ms newline
count. `TextChangeRegion.edit` (the engine's own parse for symbols, UTF-16) has the same byte-loop
shape and was not touched: its parse is followed by a pass over the whole document anyway.

## Allocations, copies, and the non-ASCII cliff

**Correction to the tables above.** Every file the harness used was pure ASCII. Swift's fast paths
for UTF-16 offsets and for `String ==` exist only for ASCII, so a file with one `é` or `©` (most real
Java files have some) took a different, much slower route: a typing request at 120,000 lines was
**17.5 ms with one non-ASCII comment line against 1.9 ms without**, and 3.2 ms against 0.44 ms at
20,000 lines. The cause was not the work the earlier sections measured; it was `NSString` and
UTF-16 access into a large Swift string, which transcoded the document to a UTF-16 buffer and built
a UTF-16 breadcrumb table for every new string, and `cachedParse.text == text`, which compares
normalized scalars (0.07 ms for ASCII, 0.78 ms with one `é`). The harness now has `--unicode`.

`PerfHarness java-allocations synthetic [--samples N]` traces the heap (libmalloc's `malloc_logger`
hook; harness only) over one steady-state typing request, with one provider kept across requests
and the request's text built before the window opens. It reports total bytes and count, the bytes in
allocations of 4 KB or more, the peak of allocations of 64 KB or more alive together, and each of
those with the code that made it. Medians of 8; the byte counts do not vary between runs.

**Copies of the document in one request (120,000 lines, 2.37 MB), before:**

| # | what | where |
|---|---|---|
| 1 | `NSString.substring(to:)`, and for non-ASCII a 2x-size UTF-16 transcode | `blankingBrokenStatements` |
| 2-5 | four `String +` temporaries, each copying everything so far | `repairedText` |
| 6 | `Array(text.utf8)` for the diff | `JavaStubReuse.reparse` |
| 7 | `Array(source.utf8)` | `SyntaxParser.parseIncremental` |
| 8 | `Array(text.utf8)` | `makeRequest` |
| 9 | `Array(source.utf8)` | `JavaExpressionTyper.receiverInfo` |

Two are necessary: the repaired text (the parse input differs from the buffer by the dummy
identifier), and the byte array the new tree keeps as its `sourceBytes`. The other seven were
value-semantics temporaries (2-5) or API-boundary copies (1, 6-9). Now: the repair builds the
result once, from UTF-8 slices of the original (`JavaCompletionRepair`); the diff, the parse and the
tree share one byte array (`parseIncremental(oldTree:bytes:)`); the request borrows the tree's
array; `receiverInfo` takes it as a parameter. Not copy-on-write savings: those assignments really
did copy, because each step changed the contents.

| per typing request | before | after | peak of large buffers, before / after |
|---|---|---|---|
| 5,000 lines | 1.01 MB | 0.33 MB | 392 KB / 196 KB |
| 20,000 lines | 3.63 MB | 0.93 MB | 1.55 MB / 0.80 MB |
| 120,000 lines | 21.50 MB | 4.93 MB | 9.47 MB / 4.73 MB |
| 120,000 lines, non-ASCII | 24.63 MB | 4.93 MB | 9.91 MB / 4.73 MB |
| 120,000 lines, one class of 24,000 methods | 23.56 MB | 7.04 MB | 9.44 MB / 4.72 MB |

The one-class file also makes about 24,700 small allocations (tree-sitter nodes), which are the 2.3 MB
difference. Everything in the window is counted, including the async machinery; text building and
the request's `CompletionContext` are not.

**Typing request time, provider only** (median of 12 requests, three runs; the range is the
spread of the three medians; milliseconds; classes of 100 methods unless noted):

| file | before | after | after, p95 |
|---|---|---|---|
| 5,000 lines | 0.294 | 0.243-0.246 | 0.27 |
| 5,000 lines, non-ASCII | not measured | 0.249-0.255 | 0.31-0.43 |
| 20,000 lines | 0.439 | 0.391-0.398 | 0.49-0.53 |
| 20,000 lines, non-ASCII | 3.18 | 0.400-0.442 | 0.56-0.61 |
| 120,000 lines | 1.93 | 1.597-1.620 | 1.75-1.88 |
| 120,000 lines, non-ASCII | 17.46 | 1.561-1.595 | 1.70-1.83 |
| 120,000 lines, one class | 16.7 | 16.0-17.3 | 18.7-20.2 |
| 120,000 lines, one class, non-ASCII | not measured | 16.3-16.6 | 17.7-19.7 |

Non-ASCII costs what ASCII costs. "Before" is the state the previous section ended in, measured the
same way on the same machine earlier in the session (that run repeated within about 1%). The ASCII
gain is small in time (1.1-1.2x) for a 4.4x cut in allocation: the saved copies are memcpy at
memory speed. The one-class file is tree-sitter (90%), as before.

**What is left at 120,000 lines (classes of 100, non-ASCII), 1.6 ms:** `repairedText` 0.73 (the
brace scan 0.55, the caret's UTF-16 to byte offset 0.13, assembling the result 0.04), the parse
stage 0.39, receiver typing 0.15, the import inserter 0.08, stubs and the rest under 0.1 each.

**Not done, with the reasons.** The brace scan is about 15 ns per brace over every brace before the
caret; making it independent of the prefix means keeping its nesting state between requests, a cache
with an invalidation rule, for a few hundred microseconds at the largest size. The two remaining
document-size buffers could become one only if every consumer of `Request.text` took bytes instead
of a `String`. In the editor `JavaNavigationText.fullText` also materializes a file-backed buffer
(necessary: the provider needs the text; not exercised by this harness), and the caret's
UTF-16-to-byte conversion is now a scan where it was O(1) for ASCII (0.13 ms at 120,000 lines).
The provider runs on the cooperative pool, so none of this is main-thread work. The main thread's
part of a request (reading 256 units for the prefix, wrapping a file-backed document in a range
reader) was read in the controller, not measured here, and this work did not touch it.

## Index publish

`JavaIndex.setSources` with 202 sources / 86,030 names took 0.37 s (4.3 µs per name) and runs on
every project shard refresh, including a single-file save. At a 216k-name classpath that
extrapolates to about a second [estimate, not measured]. This is the evidence for layering the
library names apart from the project's.

## End to end: keystroke to the popup's first draw

`swift run -c release PerfHarness java-completion-latency (synthetic [--lines N] [--per-class N] [--unicode] | project <name> [--files N]) [--samples N] [--timelines]`.
A real `TextView`, `EditorIntelligenceController`, `CompletionEngine([Symbol, Word, Snippet, Java])` and the
real provider; one word typed with 150 ms between characters. **Boundary:** the clock starts when the
typing observer has the character in the buffer and stops at the popup's first `draw(_:)`
(`CompletionLatencyTrace`, opt-in: `UMBRA_COMPLETION_TRACE=1`). Not in the numbers: the window server
and run loop delivering the key event, and the compositor putting the frame on screen. "Provider" is the
Java provider's final batch on the same clock, so first draw minus provider is the debounce, the
controller (hold, refilter, present) and the drawing. Cold = the first request after the file was opened
in this process (the first file of a run is also process-cold: JDK stubs not yet decoded); caret moved =
the first request at a new site; warm = the same site again.

### The lifecycle and the 300 ms hold

typed → `requestBegin` → `scheduled` → `taskStart` → engine `engineQueued` / `engineStart` (leading-edge
debounce: the first request after a pause and explicit ones start at once; one within 50 ms of the
previous waits for the burst to end) → providers in parallel → `snapshot` → controller `ingest` → `presented`
→ `panelDraw`. The hold parks a non-empty, unfinished update that arrives before the popup is painted, for up
to 0.3 s, so that the first paint carries the final order (rows are frozen once painted; later items append
below) and so that fallback providers' words are not painted before Java answers. It never expired in any run
(`hold released 0` everywhere); it costs nothing when Java's first update is the final one, which is the
common case after the early-delivery work. Pinned by `EditorIntelligenceControllerCompletionTests`
(`testUnfinishedCompletionWaitsBeforePainting`, `testLaterBatchDoesNotReorderFrozenRows`).

### Real projects (release, first draw in ms: median / p95; provider median)

8 files per project, 10 real `.` sites per file, 8 samples per site. Medians pooled over files.

| project | cold n=8 | caret moved | warm (same place) |
|---|---|---|---|
| sxb-stock (Gradle, 337 jars) | 33 / 49 (provider 30) | 12.5 / 23 (6) | 11.2 / 17.7 (5.9) |
| sxb-gateway (Gradle, 178 jars) | 23 / 31 (18) | 13.0 / 19 (7.0) | 12.8 / 17.5 (6.7) |
| perkeo (plain folder, 103 files) | 23 / 43 (17) | 11.6 / 18 (3.4) | 9.8 / 17.5 (3.0) |
| ecs-deployer (plain folder, 37 files) | 28 / 32 (22) | 12.2 / 20 (3.8) | 9.9 / 18 (3.4) |

Before the declaring-file fix below: ecs-deployer cold 130 / 143, caret moved 20.9 / 48, warm 14.9 / 26;
sxb-stock cold 61 / 163, caret moved 13.1 / 29. mongomigrator (earlier session, same method): warm 11.7.
Slowest warm sites are `java▮util.Objects` style fully-qualified receivers (14–16 ms at the first draw
before `hasSubpackages`, now in line with the others) and jOOQ generated code (`TableOptions▮table()`, which was
57–63 ms for the same reason).

### What the cold request spent (real projects)

`parse` of the edited file is 0.6–1.9 ms (files are 80–1,500 lines). The 80–110 ms that used to be there was
`JavaMemberLookup` re-parsing the files of **dependency source classes**: resolving each simple name in a
signature of `com.alexcova.ecs.Context` (493 lines, 68 members) walked its supertypes, and each walk parsed
every ancestor's file again with a private `JavaSyntaxParser` (a sampler showed
`resolve → nestedType → supertypeClosure → ancestorQualifiedNames → contextOfDeclaringFile → SyntaxParser.parse`).
Routed through `JavaParseMemo.shared.parsed` (same text, one parse; `members.declFileBuild` and
`members.resolve` stages), provider cold 125 → 22 ms in ecs-deployer.

### Synthetic files (first draw / provider, ms; `--samples 12`, JDK index only)

| lines | structure | text | cold | warm |
|---|---|---|---|---|
| 5,000 | classes of 100 | ASCII | 52 / 34 | 10.3 / 1.8 |
| 5,000 | one class | ASCII | 62 / 38 | 7.3 / 1.7 |
| 20,000 | classes of 100 | ASCII | 78 / 75 | 10.1 / 4.3 |
| 20,000 | one class | ASCII | 77 / 73 | 10.0 / 4.2 |
| 20,000 | classes of 100 | non-ASCII | 160 / 81 | 14.0 / 11.1 |
| 20,000 | one class | non-ASCII | 83 / 79 | 15.1 / 10.9 |
| 120,000 | classes of 100 | ASCII | 322 / 329 | 16.0 / 12.2 |
| 120,000 | one class | ASCII | 322 / 334 | 16.0 / 12.0 |
| 120,000 | classes of 100 | non-ASCII | 327 / 339 (was 322 / n/a) | **19.9 / 16.8** (was 54.6 / 51.3) |

Cold is dominated by the first full parse of the repaired text (40 ms at 20k lines, 224 ms at 120k) plus the
stub build (12 / 72 ms); the warm request is the incremental path. Flat and nested structures cost the same.
The non-ASCII rows above this paragraph were measured before the fix described in "Non-ASCII" below; the
20k / 120k rows of that table for non-ASCII text are now within a few ms of ASCII.

### Cold parse reuse: investigated, not implemented

The provider parses `repairedText` (the buffer with a dummy identifier at the caret, plus `;` and paren
repair). `JavaParseMemo` holds parses of the buffer text as it is, keyed by length and a 64-bit hash, with
no stored bytes. So (1) the memo cannot hold a tree compatible with the request's text (different bytes;
a tree for the unrepaired text would need an edit to become the repaired one, which is what `cachedParse`
already does with its own prior tree); (2) it cannot prove byte identity, which an exact-source seed needs;
(3) it has no by-file lookup, so finding the previous tree for a file would be a second index, which the
brief rules out; (4) in real projects the edited file's parse is 0.6–1.9 ms, so there is nothing to win;
only a 20k+ line file pays tens to hundreds of ms, once per open file. Decision: keep the provider's own
single-slot `cachedParse`. The memo *is* used where the same text really is parsed repeatedly: dependency
files in member lookup (above).

### Tests

`JavaCompletionControllerTests` (8, real `TextView` + controller + corpus index, no fixed sleeps),
`JavaDeclaringFileMemoTests` (6), `JavaBytePositionTests`, `JavaIndexPathsTests`, `JavaIndexTests`
(`testHasSubpackagesMatchesSubpackagesEverywhere`), engine pipeline tests in `JavaCompletionCorpusTests.swift`.
`Scripts/ci-java-tests.sh` (151 tests, ~40 s) excludes the controller tests, which need a window server.
Full `swift test`: 5,227 tests, 8 failures, all pre-existing (4 `JavaGoToImplementationTests` assertions,
2 `RecentFilesSwitcherTests`, 2 JaCoCo `JavaInstrumentationRealJDKTests`).

## Hardening pass: file switches, non-ASCII, minimap, saves, memo capacity

### Controller regression tests (`JavaCompletionControllerTests`, 17, no fixed sleeps)

A real `TextView`, `EditorIntelligenceController`, `CompletionEngine([Symbol, Word, Snippet, Java])` and the real
provider over the JDK corpus index. The switch tests model Umbra's pane host: an `EditorWorkbench` with two
documents, one `TextView` and one controller, and a switch is what `IDEWorkspace.applyState` does (select the tab,
`setState`, `documentURL`, `languageIdentifier`, then `adapter.refreshCachedDocuments()`). Waits are polls of the
state a step needs, a latch (`slowPhaseHook`) for holding the provider, or a trace event (`documentSwitched`).

Covered: popup after `.`, prefix narrowing before the engine answers, a burst of keystrokes, backspacing the dot,
accepting a member, an explicit request, a dismissed popup not reopened by a late slow phase, replacing the text;
switching files with a popup open, switching to a file whose caret sits at the same identifier offset, a slow
result arriving after a switch, switching from Java to a non-Java file (the Java provider takes no request),
closing the document during completion, returning to a previously opened document, losing and regaining window
focus (and another window losing focus leaving the popup alone), and the controller and its text view being
released with a request in flight.

Two **defects found and fixed**: a tab switch did not tell the controller anything about the *document* (only the
caret and the text moved), so (1) an open popup survived a switch when the new caret sat in an identifier starting
at the popup's anchor offset, and (2) a request in flight for the file that was left kept running (its slow phase
ran) and its result was ingested. The controller now records the document a popup or request belongs to
(`completionDocumentID`) and drops both when `adapter.currentDocument` is another one: on any adapter event, and
again when an update arrives. Both tests fail without the fix (checked by disabling the guard).

### Non-ASCII at 120,000 lines (the 55 ms): a foreign string, not the provider's algorithm

Identical files, one with a short non-ASCII header comment (`--unicode`), release, warm first draw: 16.0 ms (ASCII)
vs 54.6 ms. The provider's `repair` stage was 0.75 ms (ASCII) vs 41.5 ms; `fullText` 8 vs 6.7 ms; the controller
(`ingest` 2.4 ms, present, draw 1.7 ms) was the same in both. A sampler put 322 of 421 samples of the request in
`JavaCompletionRepair.repair` → `String._copying` → `String.UTF8View._foreignSubscript` →
`-[__NSCFString characterAtIndex:]`: the document text arrives as a string backed by `NSString`
(`String(utf16CodeUnits:count:)` in the piece tree, `NSString.substring(with:)`), and with any non-ASCII
character Swift reads its UTF-8 one UTF-16 unit at a time through `characterAtIndex` (5 MB ≈ 40 ms). An ASCII
`NSString` has a fast path, which is why the cliff only exists for non-ASCII text.

**Fix:** `JavaNavigationText.fullText` converts such a string once, with one bulk `getBytes` (`nativeUTF8`, ~1 ms),
and leaves a native string, or one that cannot be encoded, alone. Warm 120k non-ASCII: first draw 54.6 → 19.9 ms,
provider 51.3 → 16.8 ms; cold `repair` 44 → 0.9 ms. Tests: `JavaNavigationTextTests` (bytes and UTF-16 length
equal, result addressable, native string returned as is, a lone surrogate gives the same text), plus the
repaired-text equivalence suites unchanged. The remaining non-ASCII overhead (16.8 vs 12.0 ms provider) is the
one conversion plus the larger first read.

### Main-thread stalls and the minimap

`--stalls` runs a 1 ms main-run-loop heartbeat and reports gaps over 5 ms. At 20,000 lines non-ASCII the first
(cold) request showed a main-thread stall of **73 ms** between the provider's answer and `ingest` (it was what the
earlier note attributed to the minimap); with `nativeUTF8` the same request stalls **17 ms**, and the stall is the
same with the minimap off (17, 16, 17 ms vs 17, 18, 18 ms), so it is the first present and draw of the popup. While
a file opens (1 s) the heartbeat sees one long stall for `setState` and layout (750 ms at 20k lines, 710 ms at
120k) that is identical with and without the minimap; the minimap's own passes show as a few 5–6 ms gaps. A
sampler during the first seconds put 14 of 423 main-thread samples in `MinimapView.draw` (tree-sitter captures).
Warm, with non-ASCII text, the minimap adds about 3.5 ms to the first draw (14.0 vs 10.2 ms); ASCII shows none.
Conclusion: the minimap does not delay the popup in a way worth moving off the main thread; nothing changed.

### Save to completion

`java-completion-latency save (synthetic | project <name>)`: mirrors `IDEJavaSupport.refreshStubs`: write the file,
re-index the saved source root (`JavaIndexScheduler.index(force: true)` parses every `.java` file of the root),
open the shard reader (on the main actor in Umbra), `JavaIndex.setSources`, then ask for completion. Provider-level
("first suggestions" = the provider's last update); a real project's files are never written (its root is
re-parsed as is). Medians, release:

| project | root files | names | root re-index | reader open | `setSources` | completion asked while it runs |
|---|---|---|---|---|---|---|
| synthetic, 200 files, 100 jars | 201 | 45.7k | 16 ms | 0.2 ms | 196 ms | 196 ms (before the fix) |
| synthetic, 1,000 files, 100 jars | 1,001 | 46.5k | 79 ms | 0.5 ms | 205 ms | 197 ms before → **0.5 ms** after |
| synthetic, 5,000 files, 100 jars | 5,001 | 50.5k | 394 ms | 2.0 ms | 201 ms | 202 ms (before the fix) |
| synthetic, 6 modules × 1,000, 337 jars | 1,001 (one module) | 146k | 79 ms | 0.5 ms | 649 ms | 649 ms before → **0.5 ms** after |
| synthetic, 16,000-line saved file | 1,001 | 46.5k | 131 ms | 0.7 ms | 210 ms | 21 ms (20 ms idle), after the fix only |
| synthetic, syntax error in the saved file / unchanged save | 1,001 | 46.5k | 85 / 78 ms | 0.5 ms | 217 / 198 ms | 0.5 / 0.4 ms, after the fix only |
| sxb-stock (20 shards, 337 jars) | n/a | 39.8k | 158 ms | 0.9 ms | 205 ms | 3.1 ms (2.7 idle), after the fix only |
| sxb-gateway (4 shards, 178 jars) | 35 | 50.3k | 13 ms | 0.1 ms | 276 ms | 3.2 ms (3.0 idle), after the fix only |

A request issued while the rebuild runs now costs what an idle one does (the last four rows show it within 0.5 ms
of idle); a syntax error in the saved file and an unchanged save behave like an edit (the root is re-parsed
either way, and the shard writer tolerates the error).

**What blocked completion:** `JavaIndex.setSources` rebuilt the name tables inside the actor (4.2 µs per name:
~200 ms at 46,000 names, ~650 ms at 146,000), and any completion asked meanwhile queued behind it for the whole
time, after every save, in every window. The root re-index (parse of every file, scaling with the root: 80 µs per
file) and the reader open run off the actor and never blocked it. **Fix:** `setSources` is now `async`: it builds
the tables in a detached task from the new sources, then swaps them in with the rest of the state in one step;
queries asked while it builds are answered from the previous sources, and the call returns once the new ones are
in effect (a call overtaken by a newer one returns without applying). Completion during a rebuild: 196 / 648 ms →
0.5 ms. The cost that remains is background CPU, and the time before another file's *saved* classes are visible to
this one (the open buffer's own classes are served from the overlay at once): 280–730 ms in the big cases.
Tests: `testQueriesAreAnsweredFromTheOldSourcesWhileANewSetIsBuilding` (a latch holds the build; queries return the
old sources, then the new), `testTheNewestSetSourcesWinsWhenTwoOverlap`.

**Not implemented, and why:** per-file stub-shard updates and a layered base index (library names kept, project
layer rebuilt). The user-visible stall is gone, so the criterion for more machinery is background CPU (the
whole-root parse is 0.4 s per save at 5,000 files; `setSources` is ~99% library names). Recommended next if saves in
large projects show CPU or battery cost: layer the library names, then per-file shard updates (the
`JavaNameIndex.filesChanged` pattern exists). Both are bigger changes with correctness risk and need their own
equivalence tests.

### Parse memo capacity (12 entries / 24 MB)

New opt-in counters (`@_spi(Benchmarks) JavaParseMemoStatistics`: hits, parses, evictions, parses of text evicted a
moment before, time, distinct texts, peak bytes), printed by the project run (8–12 files, 10 sites each; every
completion walk reads its dependency source classes through the memo):

| project | hit rate | parses | distinct texts | evictions | parses of just-evicted text | cost of those | peak |
|---|---|---|---|---|---|---|---|
| sxb-stock | 98% (3,550 hits) | 80 | 73 | 68 | 7 | 2.2 ms of 32.6 ms | 0.1 MB |
| sxb-gateway | 93% | 14 | 14 | 2 | 0 | 0 | 0.1 MB |
| ecs-deployer | 99% (1,549 hits) | 15 | 15 | 3 | 0 | 0 | 0.1 MB |
| perkeo | 95% (1,599 hits) | 80 | 48 | 68 | 32 | 11.3 ms of 36.9 ms | 0.1 MB |

The entry count (12) is the binding limit, not the byte cap (0.1 MB held against 24 MB). Churn does happen in
projects that touch many dependency files (perkeo: 32 re-parses of evicted text), but the whole run's avoidable
parsing is 2 to 11 ms across 12 files and 120 requests, small beside a 10 to 30 ms request; the hit rate is already
93–99%. Decision: leave the capacity at 12. A raise is cheap in bytes (entries here are ~10 KB of source) but
buys nothing measurable, and the byte cap, not the count, is what protects a session with several very large
files (a tree is many times the size of its source; that retained size was not measured). If ⌘-click latency
under completion-heavy use shows churn in practice, measure with these counters first.

### Re-check against the baseline (same settings as the table above: 8 files, 8 samples)

| project | cold first draw | caret moved | warm |
|---|---|---|---|
| sxb-stock | 26 / 46 | 12.5 / 21 | 10.7 / 15 |
| sxb-gateway | 23 / 30 | 13.1 / 21 | 12.6 / 17 |
| ecs-deployer | 25 / 42 | 12.3 / 18 | 9.9 / 19 |
| perkeo | 28 / 40 | 11.7 / 19 | 10.7 / 16 |

Unchanged within noise: warm 9.9–12.6 ms, cold 23–28 ms.

## Not yet measured

Resident memory with a real classpath and the size of retained syntax trees in the memo; compositor presentation
time; a save while a Gradle sync is running; per-file stub-shard updates and a layered base index (recommended
above, not built).

## Lambda parameter inference (A/B, release, this machine's load 5-6)

Added with the contextual-inference change (`docs/JAVA_COMPLETION_QUALITY.md`, "Contextual inference for lambdas
and generic calls"). `java-completion synthetic` has two new sites, `lambda_sibling` and `generic_invocation`. Three
binaries (`HEAD~1`, `HEAD`, the change) alternated for six rounds, final-update medians: member access 0.118 /
0.118 / 0.120 ms, 3-character class name 0.727 / 0.726 / 0.736, `new` with expected type 0.562 / 0.564 / 0.565,
lambda chain 0.343 / 0.346 / 0.352, generic invocation 0.583 / 0.581 / 0.500, lambda parameter bound by a sibling
lambda 0.284 / 0.281 / 1.367. The earlier `new`/class-name 3-6 % slowdown was not reproduced (`HEAD` vs `HEAD~1`
+0.2 % / -0.2 %). Per typing request the change allocates a constant 16 KB more (325 → 342 KB at 5,000 lines).
The machine was loaded (not a quiet baseline); read the ratios, not the absolute times.

## Incomplete-code inference (A/B, release, load 2.5)

Added with the unclosed-lambda change (`docs/JAVA_COMPLETION_QUALITY.md`, "Inference while the code is incomplete"). New
`java-completion synthetic` sites: `lambda_unclosed`, `lambda_unclosed_nested`, `generic_nested`. Six alternating runs of the
previous binary and this one, final-update medians: member access 0.118 / 0.117 ms, 3-character class name 0.740 / 0.732,
`new` with expected type 0.567 / 0.566, lambda chain 0.345 / 0.351, sibling-lambda parameter 1.385 / 1.381, nested generic
invocation 1.179 / 1.183, 5,000-line file typing 0.478 / 0.474; **unclosed lambda block 0.110 / 0.295, two levels 0.143 / 0.427**
(they used to give up with the wrong answer; now they infer). Per typing request: 341.6 KB, 683 allocations before; 342.1 KB,
686 after.

