# F12 — Teardown cancellation gaps

- **Priority:** P1 · **Severity:** Medium · **Confidence:** Confirmed (B) / partly suspected (A) · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- Prior audit: `pendingTasks` removal on close/reschedule is bounded per document (not unbounded as first claimed); the remaining gap is `Workspace.connect`/`setFileSystemWatcher` and `IndexingService.connect` `for-await` loops never cancelled on teardown.
- Workflow audit: `IDEWorkspace` teardown (:1115-1158) cancels structure/blame/agent/watcher/LSP/preview thoroughly, but ~30 fire-and-forget `Task { await openDocument }` are untracked; whether `openDocument` re-checks teardown after awaits was not fully traced.
- A suspected ordering race: `IDEProjectModel.applyChanges` spawns untracked refresh tasks; its generation token bumps only on `setRoot`, so concurrent listings could apply out of order. Needs a targeted concurrent-refresh test to confirm or kill.

## Root cause

Long-lived `for-await` consumers and untracked tasks are not owned by a teardown-cancellable scope.

## Fix sketch

Store and cancel the connect/watcher tasks at teardown; give `applyChanges` a per-refresh generation; audit untracked `openDocument` tasks for post-await teardown checks.

## Complexity / Dependencies

S–M. None.

## Acceptance criteria

- Leaks instrument clean across open/close cycles; Allocations generations flat.
- Concurrent-refresh test either reproduces the splice race (then fix verified) or kills the hypothesis (record in this file).

## Tests / benchmarks

- Leaks + Allocations; new concurrent-refresh unit test; existing workspace tests.

## Out of scope

Reworking the generation-token pattern elsewhere — it is a strength; copy it, don't replace it.
