# F05 — Hover head-of-line blocking

- **Priority:** P0 · **Severity:** High · **Confidence:** Confirmed (prior audit; cited, not re-traced in workflow audit) · **Provenance:** B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `Sources/EditorIntelligence/Hover/HoverEngine.swift:29-41` spawns one Task per provider then awaits in index order. A slow provider[0] blocks a fast provider[1]; the doc comment says concurrent.

## Root cause

Sequential await over concurrently started tasks gives first-in-order, not first-to-finish, semantics.

## Fix sketch

Task-group first-wins: return the first non-nil result, cancel the rest. Preserve primary-provider filtering semantics used elsewhere in the engines.

## Complexity / Dependencies

S. None.

## Acceptance criteria

- Unit test: slow first provider + fast second provider returns the fast result and cancels the slow one.
- Hover latency signpost shows first-result time, not slowest-provider time.

## Tests / benchmarks

- New HoverEngine unit test with controlled provider delays; existing hover tests pass.

## Out of scope

Hover content/formatting; LSP hover latency itself.
