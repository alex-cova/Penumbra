# F12 — Teardown cancellation gaps

- **Priority:** P1 · **Severity:** Medium · **Confidence:** Confirmed (B) / partly suspected (A) · **Provenance:** A+B
- **Status:** ✅ Done (2026-11-04): three leaks and one crash found and fixed, the splice race reproduced and fixed; not run under the Leaks instrument · **Owner:** Unassigned

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

## Implementation notes (2026-11-04)

Measured with weak references instead of the Leaks instrument (a test builds the objects, lets go, and waits a second for them to be released), which answers "does it leak" directly and stays in the suite.

- **`Workspace.connect(to:)` and `setFileSystemWatcher` leaked the workspace: confirmed.** Each stored a `Task { for await ... }` that captured the actor strongly and waits on a stream (the adapter's, the watcher's) that never ends, so the workspace and its own task kept each other alive. Because the workspace never died, its `EventBus` never finished its streams, so `IndexingService` and `LSPWorkspaceSyncBridge`, whose tasks captured *themselves* strongly the same way, never died either. All four now capture `[weak self]` and check it per event; the actors also cancel their tasks in `deinit`, and each has a `disconnect()` for a host that wants to end the loop while the object is still referenced (`Workspace`, `IndexingService`, `LSPWorkspaceSyncBridge`, `JavaOverlayService`; the last already used a weak capture). `WorkspaceTeardownTests`: a workspace connected to an open-ended adapter, one with a watcher, and a whole window's worth (workspace, adapter, index, bridge) are all released; `disconnect()` ends the loops. Mutating `[weak self]` back to a strong capture fails two of them.
- **`EditorIntelligenceController` and its `TextView` were never released (new, not in the brief).** Two causes. The controller's event task did `guard let self` *before* `for await adapter.events`, holding itself for as long as the stream lives. And `installOverlayViews` handed the text view a scroll observer that captured the text view itself (`textView.addScrollObserver { ... textView.isUserInitiatedScroll ... }`): a cycle through a closure the view stores. Both fixed (`[weak self, weak textView]`, and the per-event weak check); the stream is still taken when the task starts, because taking it at init also delivered the `documentOpened` the old code missed, which materialized a large untitled buffer (`InteractivePathTests.testLargeUntitledKeystrokeDoesNotMaterializeForCompletion` caught that). `EditorIntelligenceControllerReleaseTests`: controller and text view are released once the window lets go; a text view alone is the baseline. The other `add*Observer` call sites (diff viewer, merge viewer) already use weak captures. Seven test files relied on the leak: they discarded the text view (`let (controller, _) = ...`), which only survived because of the cycle, so they now hold it explicitly.
- **`IDEWorkspace` teardown never ended the connect loops, and its launch task raced teardown.** `bootstrap()` ran the four connects in an untracked `Task` that captured `self`; it is now `bootstrapConnectTask`, weak, checks `isTornDown` between steps, and `teardown()` cancels it and calls `disconnect()` on the workspace and the index (`IDEJavaSupport.teardown` does the Java overlay's).
- **`openDocument(from:)` after teardown: a crash, confirmed.** The ~30 fire-and-forget `Task { await openDocument(...) }` all go through this one function, and it never looked at teardown after its awaits. A load that finished after the window closed built editors on a torn-down workspace; the new test (`IDEWorkspaceLifecycleTests.testAFileThatFinishesLoadingAfterTeardownIsNotOpened`) hit `Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value` at the host creation (`window` is nil after teardown) without the guard. It now returns after the load, after `syncWorkbench`, and in the `catch` (no error alert for a closed window). One guard in the shared function covers every caller.
- **The `IDEProjectModel.applyChanges` ordering race: reproduced, then fixed.** `refresh` reads the folder off the main actor and splices afterwards; the generation token only changes on `setRoot`, so two overlapping refreshes could apply in the opposite order of their reads. With a test seam between read and splice (`refreshHookForTesting`), an older listing that arrived last hid a file created in between (`b.txt`), and an older full rebuild (more than 200 changed folders) overwrote a newer splice. A deleted file did *not* come back, because entries the old listing marked unchanged are matched against the tree at apply time. Fix: each refresh takes a sequence number before it reads; a listing is dropped if a newer read of the same directory (or a newer rebuild) is already in the tree, a listing of another directory is still applied, and an older rebuild that meets a newer splice reads again instead of replacing it. `IDEProjectModelRefreshOrderTests` (four cases; with the checks removed the create case and the rebuild case fail).
- **Not done / not verified:** the Leaks instrument and Allocations generations were not run (the weak-reference tests stand in for them for these objects; there may be other cycles in objects they do not build). Process-lifetime tasks that are bounded by a run, not by a window (`for await` over a build or an index scan), were read, not changed. The Browser tab's `urlTask` is already cancelled in its `teardown`.
