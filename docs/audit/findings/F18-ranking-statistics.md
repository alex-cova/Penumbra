# F18 — Completion ranking has no statistics

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `DefaultRanker` (EditorIntelligence): tier×100 dominant, priority buckets clamped ±40, preselect +20, recency from a 30-entry list worth ≤3 points. `CompletionMatcher` has 6 tiers (exact > prefix > camelHump > wordStart …); no substring/fuzzy tier.
- A hardcoded `jdkImplementations` map (`List`→`ArrayList`, etc.) substitutes for usage statistics. Grep for frequency/statistics in completion and ranking returns nothing else.
- Candidate generation re-runs classify + locals + expected-type per keystroke (50 ms debounce, synchronous re-filter); slow extras arrive as a phased second update — that part is good design, keep it.

## Root cause

Ranking is hand-tuned because no usage signal is collected anywhere in the system.

## Fix sketch

Collect project-frequency counts from the name/completion indexes (types and members used in this project rank up); add a substring/fuzzy matcher tier below wordStart. Keep tier dominance so statistics nudge, not override, relevance.

## Complexity / Dependencies

M. Benefits from F15/F17 indexes as the counting source.

## Acceptance criteria

- Fixture: the project's own most-used implementation outranks the hardcoded JDK default where they differ.
- Corpus ranking-sensitive cases improve or hold; none regress beyond an agreed allowance.

## Tests / benchmarks

- Java corpus; ranking unit tests with synthetic frequency data.

## Out of scope

ML/learned ranking; cross-session personal statistics (privacy/scope — project-local counts only, and note the App Store/telemetry constraint before persisting anything).
