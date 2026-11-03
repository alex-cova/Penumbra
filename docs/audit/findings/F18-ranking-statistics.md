# F18 — Completion ranking has no statistics

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Implemented for types (see Implementation notes) · **Owner:** Unassigned

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

## Implementation notes

2026-11-03. Statistics for types are in; the substring tier and member statistics are deliberately not.

- **Source.** `JavaUsageStatisticsSource` (`fileCounts(ofIdentifiers:)`), implemented by `JavaNameIndex` from the posting table it already stores: a document frequency (files that mention the name), one dictionary lookup per identifier and root. 225 identifiers cost about 14 µs at both 5,000 and 20,000 files (Release, `java-name-index` band `usage_counts_225_identifiers`). Nothing new is stored or collected: counts are recomputed from project files on disk, so there is no telemetry or per-user profile to account for (the brief's App Store note). Umbra wires its name index to the completion provider; without a source ranking is exactly what it was.
- **Class completion.** A bounded nudge (`JavaCompletionPriority.usageCap` = 0.4, 1.6 ranker points, logarithmic, saturating at 64 files) on class-name, type-position and annotation items. It is smaller than the 0.5 gap between the scope buckets and a tier is worth 100 points, so popularity orders items inside a tier and a scope bucket and never across them (`testPopularityNeverBeatsAMatchTier`, `…TheScopeBucket`). A project class does not count its own declaring file.
- **`new`.** The leading implementation is decided once over both phases (`preferredImplementation`): the candidate the project uses most when at least two files use it and it beats the conventional stand-in's own count, else the stand-in (`ArrayList` for `List`, still in `jdkImplementations`, so a project with no signal behaves as before). The leader gets the same four-step boost the stand-in always had; every candidate also gets a usage bonus up to 1.5 so the rest order by use. This covers the project's own interfaces too (`Repo` → its most used implementation), not only the JDK ones the hardcoded map knew.
- **Acceptance.** The fixture where the project's most-used implementation outranks the JDK default is `testTheProjectsMostUsedImplementationOutranksTheJDKDefault` and, over real files and a real `JavaNameIndex`, `testARealNameIndexOverProjectFilesDecidesTheLeadingImplementation` (four files use `LinkedList`, one `ArrayList`: the leader flips). The corpus has no statistics source, so its 303 cases are unchanged by construction; none regressed.
- **Not done: the substring/fuzzy tier.** `CompletionMatcher` matches at word starts on purpose (IntelliJ's contract), and class-name completion, Go to Symbol and the member tables all bucket candidates by word-start initials (`JavaWordBuckets`). A mid-word tier would apply only to lists the ranker already holds and silently not to those lookups, and would add noise to every member list. If wanted, it belongs behind the second Ctrl+Space as an explicit wider search, not as a ranking tier.
- **Not done: member statistics.** The name index counts files per identifier, not per receiver type, so `get` or `add` would rank by how common the word is. Member usage needs counts keyed by declaring type, which the index does not hold.
- **Known approximation.** Counts are by simple name, so `java.util.List` and `java.awt.List` share a count; and they come from saved text, so an open buffer's unsaved edits are not in them.
