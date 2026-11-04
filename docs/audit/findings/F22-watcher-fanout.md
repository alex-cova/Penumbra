# F22 — Watcher batch synchronous 9-way fan-out

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed shape, Requires-measurement cost · **Provenance:** A
- **Status:** ✅ Done (2026-11-04) — measured by shape; two main-actor costs fixed, the rest cleared · **Owner:** Unassigned

## Evidence

- `IDEWorkspace.subscribeToProjectWatcher:4865-4891`: a single `onBatch` closure synchronously calls ~9 subsystems on `@MainActor` (disk sync, external change, project model, local history, git status, file indexer, languages, project systems).
- Upstream is exemplary and must be kept: one `IDEFSEventStream` for the whole app ("Nothing else watches files"), 0.5 s FSEvents latency + 150 ms coalescing, pending paths as a bounded Set — at most ~6.6 batches/s.
- Unmeasured: per-batch cost of `gitStatus.refresh` / `project.applyChanges` under a `git checkout` burst (10k files). The stream itself uses unbounded `AsyncStream` buffering; the consumer is a cheap Set insert, so backlog risk is low but unverified.

## Root cause

Fan-out is synchronous because each subsystem's handler was convenient to call inline.

## Fix sketch

Measure first under a checkout burst (Time Profiler, batch signposts). If a subsystem is expensive, move that one to a debounced async hop with generation guards — per subsystem, not a blanket async rewrite.

## Complexity / Dependencies

M worst case; possibly zero if measurement clears it. Same shape as F13.

## Acceptance criteria

- Burst trace recorded in this file; any subsystem over an agreed main-thread budget is moved off the synchronous path with no lost-change regressions.

## Tests / benchmarks

- Scripted 10k-file checkout against a fixture project; existing watcher/disk-sync tests.

## Out of scope

The single-watcher design itself; FSEvents latency tuning.

## Implementation notes (2026-11-04)

Measured by reading each handler and timing the suspect loops on a 10,000-file tree (release `swiftc -O`, not a full checkout trace in Time Profiler; that is still unrun).

**Already off the main actor (no change):** `project.applyChanges` (detached listing; more than 200 directories becomes one rebuild), `gitStatus.refresh` (async `loadSnapshot`, coalesced by `needsAnotherPass`), `localHistory.recordExternalChanges` (at most 40 files, reads detached), `diskSync.handle` (loops open entries, not batch paths; hashing detached), `fileIndexer.handle` (more than 500 paths skips the check and schedules a detached rebuild; at most 500 `stat`s otherwise), the Swift/TypeScript/Java index hooks (a `Task` after a cheap extension filter), Gradle/Maven/npm `filesDidChange` (build-file match, content compare in a `Task`).

**Two real main-actor costs, both per path, both fixed:**

| Cost | Where | 10k paths |
|---|---|---|
| `URL(fileURLWithPath:)` stats each path to decide directory-ness | `IDEWorkspace.subscribeToProjectWatcher` | 28–46 ms → 9 ms with `isDirectory: false` |
| `standardizedFileURL` per path (only when the model declares generated-source dirs) | `JavaGradleProjectModel.affectsGeneratedSources` | ~58 ms → skipped unless the path has `.`/`..` segments or a `/private/` prefix |

Nothing downstream reads the directory flag (`JavaNameIndex.filesChanged` standardizes on its own actor). Test: `JavaGeneratedSourcesTests.testPathsWithDotSegmentsAreStillStandardized`.

**Not done:** a scripted 10k-file `git checkout` trace with signposts, and the residual ~9 ms URL construction plus the per-service extension filters (still O(paths) on the main actor). If a trace shows them mattering, pass `Set<String>` to the services and build URLs only for the filtered subset.
