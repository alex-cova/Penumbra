# F15 — No inheritor/member index for `new` completion

- **Priority:** P2 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `JavaCompletionProvider.implementationStubs:912-915` states it in code: "There is no inheritor index" — `new` with an empty prefix scans only expected-type, same-package, import, and `java.lang` packages.
- `JavaIndex` (622 lines) is class-by-name only: precedence overlay > project > JAR > JDK, decoded-stub FIFO 16,384, overlay rebuilt per edit. No member, usage, or frequency index.
- Source stubs leave types unresolved until a per-walk declaring-file reparse (`DeclaringFileCache` re-reads + reparses source), so uncached member completion costs `O(hierarchy × members + declaring-file parses)`.

## Root cause

The index answers "where is class X", not "what extends X" or "what do people instantiate here".

## Fix sketch

Add an inheritor index (supertype → subtypes) maintained incrementally like the name shards; use it for empty-prefix `new` and implementation completion. Consider a member index only after measuring the declaring-file reparse cost.

## Complexity / Dependencies

L. Builds on JavaIndex shard machinery; F23 (staleness) must not regress.

## Acceptance criteria

- `new ` + empty prefix on an interface-typed site offers project implementations beyond the four scanned packages.
- Corpus cases depending on implementation discovery pass; index build time on a fixture project within existing budgets.

## Tests / benchmarks

- Java corpus; PerfHarness java scenarios; index incremental-update tests.

## Out of scope

Usage/frequency ranking (F18); cross-language index unification.
