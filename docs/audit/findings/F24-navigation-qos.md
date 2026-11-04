# F24 — Navigation awaits before caret move; breadcrumb QoS

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** B (partly A)
- **Status:** ✅ Done (2026-11-04) — stale-answer guard, supersession and off-main snapshot done; optimistic caret and breadcrumb QoS change decided against · **Owner:** Unassigned

## Evidence

- Prior audit: `JumpToDefinitionController` builds its navigation document detached (good) but Cmd-click still awaits snapshot + engine before the caret moves; breadcrumbs run at `.utility` QoS and lose to hover's `.userInitiated`.
- Workflow audit adds: the `EditorIntelligenceController` navigation path still snapshots full text (`TextSnapshot(text: textView.text)`) where `JumpToDefinitionController` already avoids the main-thread copy — multi-caret navigation acts on the primary caret only (accepted limitation, record don't fix here).

## Root cause

Correctness-first sequencing: resolve fully, then move. Perceived latency is the caret, not the resolution.

## Fix sketch

Optimistic caret: move immediately to the best synchronous target, refine when the engine returns (generation-guarded, as elsewhere). Raise breadcrumb QoS to match hover or document why it must lose.

## Complexity / Dependencies

S–M. Reuse existing generation guards; coordinate the snapshot removal with F20.

## Acceptance criteria

- Signpost: caret moves within one frame of Cmd-click on a warm index; slow-engine case refines without jumping the caret away from a user edit made in between.

## Tests / benchmarks

- Navigation tests; tap-to-target signpost timing on a fixture project.

## Out of scope

Multi-caret navigation semantics.

## Implementation notes (2026-11-04)

**Found and fixed (a correctness bug the brief did not name).** Neither navigation path checked the buffer after the engine answered. A slow answer for generation G was applied after the user had typed or moved on, so a same-file target landed on an offset of text that no longer existed and pulled the caret away from the edit. Two rapid requests also both delivered, the last to finish winning. Now:
- `NavigationResult.discardingTargets(in:changedSince:)` (`EditorIntelligenceAdapter/NavigationResult+Staleness.swift`) drops targets inside the current buffer when `contentGeneration` moved; targets in other files still open (their offsets are not the buffer's). A dropped answer shows no "no result" hint.
- `JumpToDefinitionController` keeps one `navigateTask` and cancels the previous request when a new one starts.
- `EditorIntelligenceController.navigate(kind:atUTF16Offset:)` (keyboard, gutter) no longer copies `textView.text` on the main actor: it captures `exportDocumentText()` and builds the string detached at `.userInitiated`, as `JumpToDefinitionController` already did. This was the `TextSnapshot(text: textView.text)` site the brief cites; the other two (`refreshDiagnostics`, `liveDocument`) are not navigation and stay with F20.

**Decided against.**
- *Optimistic caret.* Without the engine there is no synchronous target: the only candidate is a guess, and moving to a guess then moving again is two jumps. The perceived-latency cost is the engine and the snapshot, and the snapshot is already off-main and cached per generation (`BufferText`). Not done; revisit only if the signpost below shows the snapshot dominating.
- *Breadcrumb QoS.* `.utility` is deliberate: breadcrumbs are ambient (80 ms debounce, regenerated per caret move) and should lose to hover and navigation. Left as is.

**Not done.** The tap-to-target signpost on a fixture project; the acceptance's "within one frame on a warm index" is unmeasured. Multi-caret navigation still uses the primary caret (out of scope, recorded).

Tests (`JumpToDefinitionTargetTests`): `testAnswerForEditedTextDoesNotMoveTheCaret` (fails without the guard: caret jumps to {17,3}), `testAnswerInAnotherFileStillOpensAfterAnEdit`, `testANewerNavigationReplacesAnOlderOne`. 279 navigation and controller tests pass.
