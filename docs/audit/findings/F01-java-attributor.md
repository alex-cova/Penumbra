# F01 — No Java attributor

- **Priority:** P0 (long pole; lands in P2) · **Severity:** Critical · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `JavaTypeSystem` (Sources/JavaIntelligence): no nominal type, no strict/loose/casting contexts, no capture conversion, `lub` erased with no type arguments.
- `JavaExpressionTyper` (~1,032 lines): hand-rolled switch over ~20 node kinds; default returns `nil` = silently no completion. Ternary/switch take first arm, not `lub`. Generic method variables never bound from assignment target.
- Warm `javac` exists only for diagnostics; quoted 57 ms warm check cannot sit on the completion path.
- Corpus: 214/253 = 84.6% passing (`docs/JAVA_PARITY.md`).

## Root cause

Completion runs a typer + stub resolution, not a JLS attribution pass over a resolved symbol graph.

## Fix sketch

Build the native Phase-4 attributor sketched in `Sources/JavaIntelligence/Semantics/CLAUDE.md`: nominal attributed type, capture conversion, target-argument binding, signature IDs. Do not wire javac into completion.

## Complexity / Dependencies

XL. Depends on F14 (scope tree) and F15/F17 indexes for full effect. Start foundations early; it gates most of P2.

## Acceptance criteria

- Completion corpus above 214/253 with zero regressions on previously passing cases.
- New fixtures pass: capture conversion, diamond, anonymous, method-ref exactness, pattern switch.

## Tests / benchmarks

- Existing Java completion corpus + parity baseline (jdk26).
- Completion p50/p95 via signposts at 20k/120k-line files (requires F06).

## Out of scope

Full IntelliJ parity, ML ranking (F18), JPMS visibility (F16).
