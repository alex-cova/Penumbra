# F29 — Duplicate signposts and single-implementation protocols

- **Priority:** P3 · **Severity:** Low · **Confidence:** Confirmed (duplication) / unproven (protocol deletion candidates) · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- Three perf-observability systems: `PenumbraSignposts` (OSSignposter), `EditorIntelligenceSignposts` (identical interval logic, different subsystem, 13 lines, only 2 call sites), and `EditorPerformanceTrace` (in-process samples used by PerfHarness assertions and tests).
- `LanguageProviders` has 20 fields (4 arrays + 16 optionals) and EditorIntelligence declares 18 `*Providing` protocols; at least one, `MethodHierarchyProviding`, is an empty sub-protocol of `TypeHierarchyProviding`. Conformer counts per protocol were not taken — deletion candidates are unproven.
- Prior audit adds the same shape in the small: readiness triad + tier/fidelity double-truth, hand-wired provider `start()/stop()` (10 providers), a call-hierarchy downcast that should be a protocol, per-language statics and `java.*` run IDs in generic files.
- Explicit non-finding: grammar-pack target trios (42 generated targets) are not duplication; the Swift/TS/Java intelligence triplication is justified by differing semantics.

## Root cause

Abstractions were added per feature as languages landed; nobody has done the consolidation pass.

## Fix sketch

Delete `EditorIntelligenceSignposts`, call OSSignposter directly (keep `EditorPerformanceTrace` — it has harness consumers). Count conformers per `*Providing` protocol; merge only proven single-implementation, no-behaviour protocols. Replace hand-wired lifecycle with a registration loop where the pattern is truly uniform.

## Complexity / Dependencies

XS for signposts; S–M for the protocol pass, gated on conformer counts.

## Acceptance criteria

- Grep: one signpost wrapper remains; Instruments still shows intervals from both former subsystems.
- Protocol merges (if any) land with zero test changes outside the merged declarations.

## Tests / benchmarks

- Full PenumbraTests + UmbraTests suites; EditorPerformanceTraceTests must pass untouched (it is a keeper).

## Out of scope

`RefactoringEngine` — a prior removal claim was falsified by its own tests; keep and migrate only with tests/docs. Tiered-vs-Routed dispatch — retain both, document the distinction instead.
