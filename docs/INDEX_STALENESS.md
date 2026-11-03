# Index staleness: what protects what

F23 asked for "one documented staleness scheme". There is not one, and there should not be: the
guards below protect against three different races. What follows is each index, what it holds, how it
knows it is stale, and what makes it look again. Read it before adding an index or a trigger.

## The three guards

| Guard | Protects against | Used by |
| --- | --- | --- |
| **Document version** | Re-parsing an open buffer that has not changed (a selection-only update) and applying results for text that has moved on | `JavaOverlayService`, `IndexingService` |
| **Stamp** (size + modification date) | Trusting a persisted artifact (a shard on disk) that no longer matches its source | `JavaIndexScheduler` / `JavaIndexShardReader.readStamp`, `JavaNameIndex` per-file stamps, `JavaSharedShardHub` |
| **Generation + pending edits** | An edit or delete arriving while a cold walk is still parsing, and a walk that a newer one has overtaken publishing anyway | `SourceFileIndex` (Swift, TypeScript) |

They are not interchangeable. A version cannot tell whether a file changed on disk; a stamp cannot
tell whether a buffer moved on; neither orders a walk against an edit. Merging them would lose one of
the three checks.

## The indexes

| Index | Holds | Population | Stale when | Looks again because |
| --- | --- | --- | --- | --- |
| `JavaIndex` overlay | stubs of open Java buffers | open documents | `document.version` moved | `JavaOverlayService` on `documentOpened/Edited/Changed`, 300 ms debounce, applied as a per-document delta |
| `JavaIndex` project shards | stubs of project source roots | files on disk | shard stamp ≠ root stamp | the scheduler at project open and model apply; `IDEJavaSupport.filesDidChange` re-indexes a changed root with `force` (a regular root's stamp is its directory's own mtime, which an in-place edit does not move) |
| `JavaIndex` generated roots | stubs of annotation-processor output | files on disk | **content** stamp ≠ shard stamp | see below |
| `JavaIndex` JAR/JDK shards | class stubs | immutable files | jar/JDK stamp | project open, JDK change; `JavaSharedShardHub` checks the shard header per request |
| `JavaNameIndex` (`refs.idx`) | identifier → files | project files on disk, plus an overlay for open buffers | per-file stamp | `filesChanged` from the watcher (incremental), `setOverlay` for unsaved text |
| `JavaInheritorTable` | supertype simple name → project subtypes | project shards (built from them) and the overlay | dropped with `setSources`; overlay rebuilt per `generation` | same as the shards it is built from; no file of its own |
| `JavaMemberTable` | project members for Go to Symbol | same | same | same |
| `SymbolIndex` | symbols and words | **open documents only**, keyed by `DocumentID` | `document.version` moved | `IndexingService` on workspace events; never walks disk |
| `SourceFileIndex` (Swift, TypeScript) | declarations per file | files on disk + open buffer lookup | a newer walk, or an edit during one | generation token; pending edits merged before publishing |

## `JavaNameIndex` and `SymbolIndex` do not overlap

The brief asked for the query paths to be compared. `SymbolIndex` only ever holds open buffers (it is
keyed by `DocumentID` and fed by workspace events); `JavaNameIndex` holds the project on disk. They
meet only on open Java buffers, and they answer different questions: `SymbolIndex` feeds word and
symbol completion and the duplicate-symbol check, `JavaNameIndex` answers "which files mention this
identifier" for usages, rename and call hierarchy. No code path asks both the same question, so there
is nothing to merge. For Java, `JavaGoToDefinitionProvider` and the other primary providers make the
generic ones stand down (`LanguagePolicy`).

## Generated sources

Annotation processors write `build/generated/.../p/Foo_Impl.java` in place, in a directory whose own
mtime does not move, and those directories are not name-index roots. Two things had to be true for the
index to follow them, and neither was:

1. **The stamp.** A generated root (`SourceRoot.isGenerated`) is stamped by what it holds: the count
   and total size of its `.java` files and the newest modification time among them and their
   directories (`SourceRoot.contentStamp`, a stat per entry, no reads). Any file added, removed,
   rewritten or renamed moves it, so the scheduler's ordinary freshness check is enough and nothing is
   deleted before a rebuild. Cost, measured in a debug build (release is faster): 1,000 files 7 ms, 10,000 files 37 ms,
   50,000 files 182 ms, against microseconds for a directory stamp. It runs on the scheduler's background task at
   model apply and at each debounced refresh, never while typing.
2. **The trigger.** `IDEJavaSupport.filesDidChange` hands a watcher batch to
   `JavaGradleProjectModel.affectsGeneratedSources` (a `.java` file or directory inside a declared
   generated directory, the directory itself, or a parent of it: `build/` appearing after a first
   build, vanishing on a clean). A match schedules `refreshGeneratedSources`, debounced 800 ms so a
   build that writes for seconds is looked at once. `buildSucceeded` (a Gradle or Maven task Umbra
   ran) calls the same method. It works out its targets from the filesystem at that moment, so
   directories that did not exist when the model was read are picked up, and it republishes only when a
   root was re-read or a cleaned directory's shard has to be dropped.

What this does not do: Umbra never *runs* annotation processing. The warm `javac` server and the cold
CLI run `-proc:none` (except for a project's own Lombok), so regeneration needs a build, Umbra's or
anyone's; the index follows it. Generated roots are not name-index roots, so Find Usages and Rename do
not search generated code.

Tests: `JavaGeneratedSourcesTests` (stamp, scheduler, watcher-path decision),
`IDEGeneratedSourcesTests` (the real watcher, Java support and index: first build, in-place rewrite,
`clean`).
