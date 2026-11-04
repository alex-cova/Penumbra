# F29 — Duplicate signposts and single-implementation protocols

- **Priority:** P3 · **Severity:** Low · **Confidence:** Confirmed (duplication) / unproven (protocol deletion candidates) · **Provenance:** A+B
- **Status:** ✅ Done (2026-11-04) — one signpost implementation, one empty protocol and two dead requirements deleted, Java lifecycle and its downcast replaced by a loop; the rest decided against with reasons · **Owner:** Unassigned

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

## Implementation notes (2026-11-04)

**Counted first (the brief's "conformer counts were not taken").** Conformers per `*Providing` protocol in `EditorIntelligence`, source plus tests: 16 of the 18 have two or more (Rename 11, Code Actions 10, Formatting 9, Semantic Tokens 6, Signature Help 7, Call Hierarchy 7, …). The two with one are `CommandCompletionProviding` (kept: it carries behaviour, a default `provide`, and its doc names language providers as further conformers) and `MethodHierarchyProviding` (an empty marker). So the "deletion candidates" were one, not many.

**Done.**
- **Signposts.** There were two `OSSignposter`s, not three systems (`EditorPerformanceTrace` is the keeper and is untouched). `EditorIntelligence` cannot use `Penumbra`'s (the layering runs the other way) and Instruments filters on subsystem, so deleting one outright would have lost a subsystem. Instead the interval logic lives once, in `PerformanceSignposter` (`EditorIntelligence/Performance`): `PerformanceSignposter.editorIntelligence` is the `"EditorIntelligence"` channel and `PenumbraSignposts` is a thin forwarding wrapper over the `"Penumbra"` channel, so its 33 call sites did not change. `EditorIntelligenceSignposts` is deleted. Both subsystems still emit.
- **`MethodHierarchyProviding`** (empty sub-protocol, one conformer, no tests) is gone: `LanguageService.methodHierarchy` and `LanguageServiceRegistry.methodHierarchy(for:)` are typed `TypeHierarchyProviding`, and the slot (not a protocol) says it answers for a method. Its doc moved onto the slot.
- **Two dead protocol requirements** found while tracing the "readiness triad" and "tier/fidelity double-truth": `isReady(for:)` had no caller and no override, and was worse than dead (the registry deliberately reads the `unavailableFeatures` property, so an override would have been ignored); `fidelity(of:)` had no implementer. Both are removed; the registry derives fidelity from the tier, which is all it ever did, and the `LanguageServiceTier` doc now names `unavailableFeatures`.
- **Hand-wired lifecycle and the downcast** in `JavaLanguageService`: nine providers each had the same `setOpenBufferLookup(...)` line in `start` and again in `stop`, and `setCallHierarchyOpenBuffer` downcast to two concrete types (silently doing nothing for a third). One small protocol, `JavaOpenBufferReading`, which the ten providers conform to (their signatures were identical), replaces both: `start`/`stop` loop over `openBufferReaders`, and the call-hierarchy slot is typed `any CallHierarchyProviding & JavaOpenBufferReading`, so a provider that cannot take the buffer no longer compiles. The set of providers is exactly the old one.

**Decided against.**
- **`java.run` / `java.debug` / `java.stop` toolbar ids** in the generic `IDELanguageModule`: the comment says they stay on purpose and `IDEModuleContributionTests` pins them; changing them is a behaviour change and a test change, which the acceptance criterion rules out. Left, documented.
- **Per-language statics** ("prior audit"): not specific enough to act on and nothing found that is wrong.
- **`RefactoringEngine`, Tiered-vs-Routed dispatch**: out of scope per the brief.
- No other protocol merge: with two or more conformers each, a merge would change behaviour or lose a distinction.

**Verified.** Grep: one signpost implementation; no references to `EditorIntelligenceSignposts`, `MethodHierarchyProviding`, `isReady(for:)` or `fidelity(of:)` remain. No test file changed.
