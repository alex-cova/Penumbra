# F15 — No inheritor/member index for `new` completion

- **Priority:** P2 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Implemented for project sources (see Implementation notes) · **Owner:** Unassigned

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

## Implementation notes

2026-11-03. `JavaInheritorTable` (project shards, built lazily off the actor like `JavaMemberTable`; open buffers rebuilt per generation, a buffer's version of a class replaces the saved one; the query scope hides shards) maps the simple name of each written supertype to the project classes that name it. It is a candidate filter, not an answer: `JavaInheritors.subtypes(of:index:)` resolves each candidate's supertypes against its declaring file and walks transitively, so two interfaces called `Repo` in different packages do not mix. Consumers: `new ` with an empty prefix now offers project implementations in any package (`ExpectedNewProjectImplementation*`, transitive and abstract-excluded, fail without it), the type hierarchy's subtype expansion (no longer decodes every project class), and Go to Implementation for a project type.

Decisions and limits:
- **Scope is project sources only.** JARs and the JDK are left out: indexing ~30,000 JDK classes for implementation lists costs far more than it returns, and the brief's acceptance is project implementations. `List<User> x = new |` still needs a typed prefix for library classes outside the scanned packages.
- **Go to Implementation keeps the closure scan for a library target.** A project class can sit below `java.util.List` through `AbstractList`, which the table cannot see; `testProjectClassBelowALibraryTypeThroughALibraryClassIsFound` fails if the scan is dropped. A project target cannot be extended through a library class, so it uses the table. The anonymous-class scan still lists every project class.
- No format change: nothing was added to the shard files, so no re-index and nothing for F23 to worry about. The table lives and dies with `setSources`, as the member table does.
- Measured (`PerfHarness java-inheritors synthetic`, Release, stubs already resolved, so the scan is understated compared with source stubs that reparse their declaring file): 5,000 classes: table 6.2 ms cold including its build, 0.23 ms warm, closure scan 6.1 ms; 20,000 classes: 12 ms cold, 0.69 ms warm, scan 26.8 ms; both agree on the result. Large-file completion unchanged (`java-completion synthetic`).
- Not done: a member index (the brief says measure the declaring-file reparse first; not measured), usage/frequency ranking (F18).
