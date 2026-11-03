# F22 — Watcher batch synchronous 9-way fan-out

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed shape, Requires-measurement cost · **Provenance:** A
- **Status:** Open · **Owner:** Unassigned

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
