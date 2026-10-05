# Java indexing plan

Status: implemented. Measurements below are release medians from Oct 4 2026 (JDK 26). `--jars 200` is 86,030 names across 202 sources (JDK `ct.sym`, 500 project classes, 200 synthetic JAR shards of 400 classes). `setSources` on that classpath was 0.175 s before the class-name buckets and 0.184 s after.

### Section 0 baselines (parent)

`java-completion synthetic`:

| site | `--jars 0` | `--jars 200` |
|---|---|---|
| `class_name_one` (`S`) | 3.28 ms | 60.7 ms |
| `class_name_short` (`Str`) | 1.80 ms | 32.5 ms |
| `class_name_long` (`ArrayLi`) | 1.55 ms | 29.9 ms |
| `class_name_hump` (`NPE`) | 1.49 ms | 23.8 ms |
| `new_expected` (`new Arr`) | 1.79 ms | 35.0 ms |
| `member_access` | 0.11 ms | 0.14 ms |
| `lambda_chain` | 0.30 ms | 0.62 ms |
| `statement_expected` | 0.18 ms | 1.02 ms |

`java-name-index synthetic` (5,000 files, shard 1.44 MB): no-change `build` 59.8 ms, one-file `filesChanged` 34.3 ms.

### After sections 1–3

Class-name sites (`classes(matching:)` buckets, section 1):

| site | `--jars 0` | `--jars 200` |
|---|---|---|
| `class_name_one` | 1.18 ms | 6.09 ms |
| `class_name_short` | 0.72 ms | 3.07 ms |
| `class_name_long` | 0.32 ms | 1.47 ms |
| `class_name_hump` | 0.31 ms | 0.31 ms |
| `new_expected` | 0.60 ms | 5.67 ms |

Qualified-name map (section 2), `--jars 200`. `new_expected` is also a class-name query, so its drop is mostly section 1; `statement_expected` is the lookup:

| site | before | after |
|---|---|---|
| `member_access` | 0.14 ms | 0.11 ms |
| `lambda_chain` | 0.62 ms | 0.42 ms |
| `statement_expected` | 1.02 ms | 0.17 ms |

`refs.idx` update (section 3):

| | no-change `build` | one-file `filesChanged` |
|---|---|---|
| synthetic, 5,000 files | 59.8 → 38.5 ms | 34.3 → 9.4 ms |
| `~/Developer/sicarx`, 11,412 files, shard 5.8 MB | 303 → 213 ms | 150 → 44 ms |

The no-change `build` still walks the source tree to compare stamps. It no longer inverts the postings.

### Follow-up

`classes(matching:)` ranks with `CompletionMatcher.tier` and decodes stubs only for the names it keeps. `--jars 200`, same 86,030 names:

| site | after sections 1–3 | after `tier` |
|---|---|---|
| `class_name_one` | 6.09 ms | 2.65 ms |
| `class_name_short` | 3.07 ms | 1.48 ms |
| `class_name_long` | 1.47 ms | 1.55 ms |
| `class_name_hump` | 0.31 ms | 0.31 ms |
| `new_expected` | 5.67 ms | 2.37 ms |

A no-change open compares stamps with one `getattrlistbulk` pass per directory (`JavaSourceStampScan`), and a save keeps the reader `rewrite` already built instead of decoding the string table again:

| | no-change `build` | one-file `filesChanged` |
|---|---|---|
| synthetic, 5,000 files | 38.5 → 4.4 ms | 9.4 → 8.6 ms |
| `~/Developer/sicarx`, 11,412 files | 213 → 100 ms | 44 → 41 ms |

The save still rewrites the whole shard; the string-table decode was a few milliseconds of that. The decoded-stub cache drops its oldest entry when it fills, and Find Usages no longer stats every candidate path.

The shard layout, stamp checks and parallel scheduler stay as they are. Three paths used to cost time in proportion to the whole classpath or the whole source root:

- Class-name completion and Go to Class run `CompletionMatcher` over every class name that contains the query's first letter.
- `classStub(qualifiedName:)` visits every shard ahead of the JDK, so a JDK type and a missing name both cost one walk of the classpath.
- Saving one `.java` file rewrites its root's `refs.idx` after turning every posting back into strings, and opening a project does the same inversion just to compare stamps.

Sections 1 and 2 stay in memory, in `Sources/JavaIntelligence/Index/JavaIndex.swift`. Section 3 changes how `refs.idx` is updated, not its format. Section 0 adds the measurements the other three are judged by, so it lands first, on the parent commit.

## 0. Measure a classpath, not just the JDK

Baseline, `swift run -c release PerfHarness java-completion synthetic` (JDK 26 `ct.sym` plus 500 project classes, two sources), Oct 4 2026:

| site | median |
|---|---|
| `class_name_short` (`Str`) | 1.97 ms |
| `class_name_long` (`ArrayLi`) | 1.64 ms |
| `new_expected` (`new Arr`) | 1.86 ms |
| `member_access` | 0.12 ms |
| `class_name_short`, 5k-line file | 13.4 ms |

Class-name sites already cost more than fifteen times a member access, and that is with the JDK alone. A Gradle project adds a few hundred JAR shards and well over 100,000 names, and the profile shows neither.

- Add `--jars N` to `java-completion`: write N synthetic JAR shards (precedence 2, a few hundred classes each under their own packages, names built from a fixed word list such as `Default`, `Abstract`, `Http`, `Json`, `Request`, `Service`, `Builder`, `Factory`, `Exception`, some of them nested). `--jars 200` is roughly a Spring Boot classpath. Print the name and source counts in the header.
- Add two sites: `class_name_one` (`S`, the query after the first keystroke, which matches the most names) and `class_name_hump` (`NPE`).
- Add `java-name-index <java-source-directory|synthetic> [--files N]`: build the identifier index, then time a `build` with nothing changed and a `filesChanged` for one edited file (each sample changes one identifier), and print the shard size. `synthetic` writes N files from a fixed vocabulary (default 5,000).

Record `--jars 0`, `--jars 200` and `java-name-index synthetic` here before section 1, 2 or 3 lands.

## 1. Bucket class names the way members are already bucketed

`classes(matching:)` has no fast path. Every query, a plain prefix like `Str` included, scans every base name that contains its first letter (`String.contains(Character)`), runs `CompletionMatcher.match` on each (several array allocations per call), and sorts every match. The binary search only serves `classes(simpleNamePrefix:)`. Callers: the class-name paths of `JavaCompletionProvider` (type names, `new`, statements; annotations with a limit of 400) and Go to Class (`IDEJavaClassesPaletteProvider`, a limit of at least 300).

**Shared buckets.** Move `wordInitials(of:_:)`, the 256 buckets, the query's bucket key and `isSubsequence` out of `JavaMemberTable` into one small internal type (say `JavaWordBuckets`) that the member table and the class table both use. A bucket holds `Int32` indexes into its own table. (`wordInitials` is already internal; the point is that neither table reaches into the other.)

**The invariant.** A name must sit in the bucket of every position where `CompletionMatcher` can anchor the query's first character: index 0 and every position `CompletionMatcher.wordStarts` returns. `wordInitials` covers all of them but one. A digit after a letter (the `6` in `Base64`, the `3` in `S3Client`) starts a word for the matcher but is not a bucket key, so Go to Symbol already misses `64` → `toBase64`. Add "a digit after a non-digit" to `wordInitials`. Take the query's key the same way, from its first UTF-8 byte lowered by ASCII rules only, as `CompletionMatcher` lowers. `String.lowercased()`, which `JavaMemberTable.matches` uses today, can move a non-ASCII first letter to a different lead byte (`Σ` and `σ`).

**Build.** At the end of `rebuildBaseIndex()`, after the existing sort, walk `baseNameIndex` once and add each entry to its buckets. The overlay table stays a linear scan; it only holds the open buffers' classes.

**Query.** `classes(matching:)` takes the query's bucket. For each entry it checks visibility, then the in-order byte check against `lowerSimpleName` (every match tier implies the query is a subsequence of the name), and only then calls `CompletionMatcher.match`. The bucket of a common letter is still a large share of the classpath, so the pre-filter matters as much as the bucket.

Keep a running top of `limit` unique qualified names, ordered as today: match tier, then precedence, then shorter simple name, then qualified name. Use the member table's append-then-trim at `2 × limit`, plus a qualified-name → slot map rebuilt at each trim: a second definition of a name already held replaces it only when its precedence is lower. Two definitions of one qualified name have the same simple name and so the same tier, which is why this returns what today's dedupe-then-sort returns.

**All-caps prefix.** `classes(simpleNamePrefix:)` with an all-caps pattern (`ALE`) scans the whole table with `matchesCamelHump`. Scan only the bucket of the pattern's first letter: every ASCII uppercase letter is a bucket key, so every name the hump check accepts is in it. Keep the full scan when that letter is not ASCII, since `matchesCamelHump` uses `Character.isUppercase`.

**Exact simple names.** Three callers want the classes with one exact simple name and get them by asking for a prefix and filtering: `JavaUnresolvedTypeInspection`, `JavaUnresolvedImportInspection` (once per single-type import, on every analysis pass) and the import quick fix in `JavaCodeActionProvider`. Each call decodes up to `limit` stubs only to discard them (`List` decodes `ListIterator`, `ListResourceBundle`, …), and an all-caps name (`UUID`, `URL`) also runs the full hump scan. Add `classes(simpleName:)`: the equal range of `lowerSimpleName` by binary search in both tables, filtered to an exact `simpleName`, deduplicated by qualified name keeping the lower precedence, stubs decoded only for those. Switch the three callers to it; their filters already require that simple name, so their results do not change.

No shard format change. `setSources` already sorts every name, and the buckets are one more walk of that array; check that `setSources` on `--jars 200` does not get noticeably slower.

**Tests** (`JavaIndexTests`, `JavaMemberIndexTests`):

- The existing `array`, `CHM` and overlay-snapshot cases still pass. `classes(matching: "oo")` matches nothing in that fixture, so it proves little on its own.
- Equivalence: keep today's `classes(matching:)` loop in the test file as the reference and compare ordered results for every one- to three-character prefix of a name set with the awkward cases (`Base64`, `S3Client`, `URLConnection`, `_Internal`, `$Proxy12`, a non-ASCII name, one qualified name in both a project shard and a JAR shard, a shard hidden by `queryScope`), plus `uC`, `NPE` and `64`, with a small `limit` so trimming runs. Do the same for `classes(simpleNamePrefix:)` with all-caps patterns.
- With `@testable import EditorIntelligence`, check for every name in that set that `wordInitials` yields the lowered character at each `CompletionMatcher.wordStarts` position.
- Go to Symbol finds `toBase64` for `64`.

**Measure** `class_name_one`, `class_name_short`, `class_name_long`, `class_name_hump` and `new_expected` with `--jars 0` and `--jars 200`.

## 2. Remember which shard answers each qualified name

`classStub(qualifiedName:)` checks the overlay, then walks `sortedSources` in precedence order, hashing the name twice at each visible shard (the `decodedStubs` key and the reader's offset table). The JDK has the highest precedence number, so the walk is paid in full by a miss and by every JDK type: `java.lang.String` visits every project and JAR shard first. Type resolution asks for several candidate names per reference (same package, each import, `java.lang`), so most calls are one of those two cases.

Add `winningSource: [String: Int32]`, from each qualified name to the position in `sortedSources` of the first shard that defines it. Build it in `rebuildBaseIndex()`, which then walks `sortedSources` instead of `sources`, keeping the first position seen for each name.

- Store the position, not an index into `baseNameIndex`: a `NameEntry` has no reader, and `decodedStubs` is keyed by position.
- "First in `sortedSources`" is the rule, not "lowest precedence". Every project shard (main, test, each module) has precedence 1, and today's walk returns the first of them.

`classStub` then checks the overlay, then the map. No entry returns `nil` at once: no shard has the name. An entry whose shard is visible decodes through `decodedStubs` and that shard's reader, as today. When the query scope hides that shard (a class in both a test and a main source set, asked from main), or its stub fails to decode, continue today's walk from the next position; no earlier shard has the name. The per-shard offset tables stay, since they decode one stub. `allQualifiedNames` and the reader's offset table come from the same loop in `JavaIndexShardReader.init`, so the map and the readers agree.

Cost: one dictionary entry per distinct qualified name, sharing string storage with `baseNameIndex`, a few megabytes on a 200,000-name classpath.

**Tests** (`JavaIndexTests`): a name in a project shard and a JDK shard returns the project stub, and with a scope that hides the project shard, the JDK stub; two precedence-1 shards with the same name return the one first in `sortedSources`, and with a scope hiding it, the other; a name in no shard returns `nil` with and without a scope.

**Measure** `member_access`, `lambda_chain`, `statement_expected` and `new_expected` with `--jars 200`; each resolves JDK types on every request.

## 3. Update `refs.idx` instead of rebuilding it

What a save costs today: `JavaNameIndex.filesChanged` calls `sync(only:)`, which opens the shard and calls `allEntries()`: one `Set<String>` insert per posting, that is per (file, identifier) pair in the root. It re-tokenizes the changed files and hands every entry to `JavaNameIndexShardWriter.write`, which interns every pair again through `StringTableBuilder` and rebuilds the postings as `[UInt32: [UInt32]]`. Then it opens the new shard, which decodes the whole string table and rebuilds the identifier dictionary. All of it runs on the `JavaNameIndex` actor, so a Find Usages query waits behind the save. `build` (project open, Gradle sync) calls `allEntries()` too, before it knows whether anything changed, only to read stamps that `reader.files` already has.

An earlier version of this plan added a forward section (file → identifier ids, format version 2) and tombstones for deleted files. Neither is needed. The shard is one file written atomically, so any update writes all of it; the slow part is hashing strings per posting, not finding a file's old identifiers. The posting runs already hold file ids, so the update can work on ids alone:

- **Stamps first.** Compare stamps against `reader.files` (with a path → id map built from it). With nothing changed, return the existing reader without touching the postings.
- **New file ids.** Each surviving file gets a new id, with deleted files left out so ids stay dense; new files take the next ids. `indexedFileCount` and `candidateFiles` need no change, which tombstones would have broken (`indexedFileCount` returns `files.count`).
- **Copy runs.** Copy each identifier's posting run, translating ids through that table and dropping the ids of deleted and changed files: one array lookup per posting, no strings.
- **Add runs.** Append the changed and new files' ids to the runs of the identifiers they now contain. An identifier already in the shard keeps its string id (the reader maps identifier → `(offset, count)` today; add the id). A new identifier or path is appended to the string table, whose bytes are copied as they are with the count updated.
- **Drop empty runs** from the index table. Their strings stay until a full write; when orphaned strings pass a quarter of the table, write from scratch instead.

Put this in `JavaNameIndexShardWriter.rewrite(from:removing:replacing:to:)`. Both `sync(only:)` and the full rescan use it when a readable shard exists; `write` stays for a missing or unreadable shard and for the orphan threshold. `allEntries()` stays for the round-trip test.

**Tests** (`JavaNameIndexTests`):

- `testFilesChangedUpdatesIncrementally` indexes one file, so it never checks that an untouched file survives. Add a second, untouched file and assert its identifiers are still found.
- Equivalence: after a sequence of `filesChanged` calls (edit, create, delete, edit again, a new identifier, the last use of an identifier removed), the shard's `allEntries()`, compared by path, equals what `build` writes into an empty cache directory. Run the same sequence through `build` instead of `filesChanged`.
- `indexedFileCount` drops after a deletion through `filesChanged`.
- `testShardRoundTrip` does not change, since the format does not.

**Measure** with `java-name-index`: the no-change `build` and the one-file `filesChanged`, on `synthetic` and on a real project's source root.

## Order

1. Section 0 on the parent commit, with the baselines recorded here.
2. Section 2: the smallest change, and results do not change.
3. Section 1, with `classes(simpleName:)` and the `wordInitials` fix.
4. Section 3, in `Sources/JavaIntelligence/Storage/JavaNameIndexStore.swift` and `Sources/JavaIntelligence/References/JavaNameIndex.swift`.

Each lands with its before and after numbers. Then update `Sources/JavaIntelligence/CLAUDE.md`: the class table is bucketed by word start like the member table, `classes(simpleName:)` exists, `refs.idx` is updated in place, and the new PerfHarness options and command. Add `java-name-index` to the PerfHarness usage text.

## Not in this plan

- Moving `filesChanged` off the `JavaNameIndex` actor. The follow-up above took the decoded-stub flush, the per-candidate `fileExists`, the reader rebuilt from the rewrite's tables, and the stamp walk.
