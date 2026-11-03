# F24 — Navigation awaits before caret move; breadcrumb QoS

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** B (partly A)
- **Status:** Open · **Owner:** Unassigned

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
