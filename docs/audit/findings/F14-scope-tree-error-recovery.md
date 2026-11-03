# F14 — JavaScopeTree unwired; ERROR-node local loss

- **Priority:** P2 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `JavaScopeTree` (Sources/JavaIntelligence/Semantics, ~982-line memoized successor) has zero callers in `Completion/` (grep). Live completion runs per-query `JavaLocalScope` ancestor walks, `O(depth × siblings)` per query.
- `JavaLocalScope:59-68` documents ERROR-node collapse: locals in a malformed method are unrecoverable; only parameters survive.
- Error recovery elsewhere is a heuristic stack (dummy identifier, `;`/paren repair, receiver text scanner, synthetic re-parse) with silent-nil exits that present as "no suggestions", indistinguishable from a legitimately empty result.

## Root cause

The scope model was rebuilt but never wired into the provider path; recovery heuristics accumulated instead.

## Fix sketch

Wire `JavaScopeTree` into `JavaCompletionProvider`; add error-recovery attribution so declarations before the ERROR region still resolve; log/meter silent-nil exits distinctly from empty results.

## Complexity / Dependencies

M. Prerequisite for F01 full effect.

## Acceptance criteria

- Malformed-file fixture: locals declared before the error complete correctly.
- Scope-tree path used in provider (grep + test); no completion regressions on corpus.

## Tests / benchmarks

- Malformed-file completion tests; Java corpus; scope-tree ~6 ms/2k-line figure re-verified end-to-end (it is scope-only today).

## Out of scope

Full attributor (F01).
