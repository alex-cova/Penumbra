# Java completion: real-project quality

How good the suggestions are, as opposed to how fast (`docs/JAVA_COMPLETION_BASELINE.md`) or whether a
symbol is found at all (`docs/JAVA_DIFFERENTIAL.md`, which scores top-8 at a 2-character prefix and is
saturated at 100% on reference sites). Reproduce:

```bash
JAVA_QUALITY=1 JAVA_QUALITY_STATS=1 JAVA_QUALITY_OUT=/tmp/q.txt \
  swift test --filter JavaCompletionQualityTests/testQualityBaseline
```

`JAVA_QUALITY_STATS=1` gives the provider the project's identifier document-frequency counts, as Umbra's
name index does in the app; `0` is the pure semantic ranking. Other knobs: `JAVA_QUALITY_PREFIX` (default 1),
`JAVA_QUALITY_FILES` (30), `JAVA_QUALITY_POSITIONS` (60), `JAVA_QUALITY_VALIDITY_SITES` (120),
`JAVA_QUALITY_EXTRA=name=/abs/src,...` (more source roots), `JAVA_QUALITY_DEBUG=File.java:offset` (print the
ranked list at one site). Code: `Tests/PenumbraTests/JavaIntelligence/Differential/JavaCompletionQualityHarness.swift`.

## Oracle (what "correct" means here)

- **Expected candidate = the developer's choice** at that site in gson 2.11.0 and jackson-core 2.17.2 (the pinned
  checkouts of the differential harness), kept only where `javac` (`Trees.getElement`) resolves the identifier to a
  symbol of the same name, so the choice is also compiler-valid. A different candidate in the list is *not*
  necessarily wrong, so recall is a lower bound on usefulness; at a 1-character prefix many members are equally valid
  and only usage statistics separate them. That is why R@1 is far below R@8.
- Sites: 30 stride-sampled files, 60 stride-sampled identifiers each, declarations skipped (naming something new has
  nothing to recall), typed prefix = first character, the identifier's tail deleted. 1,779 sites.
- Variant `broken-line` additionally deletes the rest of the line (statement unterminated, parentheses unbalanced).
- **Invalid-candidate rate**: the top three candidates *of the same kind as the developer's symbol* are written in
  place of the real name and the file is compiled by the warm javac server; a candidate is invalid if that adds a
  `cant.resolve`, `report.access`, `not.def.public`, `non-static.cant.be.ref` or `abstract.cant.be.accessed` error.
  A **control** (a name that cannot exist) must be flagged at the same site or the site is not scored: gson's
  `module-info` stops javac before attribution, so only jackson-core sites count (120 of 240 controls fired).
- **Incorrect insertion**: the developer's candidate is accepted the way the editor accepts it
  (`CompletionInsertion.resolve`, plus additional edits) and the result is parsed; any syntax error is a bad insertion.
  `exact` = the result is byte-identical to the original file.

## Before and after (1-char prefix, `complete` variant)

| | before | after, no statistics | after, with statistics |
|---|---|---|---|
| Recall@1 | 51.8% | 53.7% | 55.6% |
| Recall@3 | 78.6% | 79.3% | 82.9% |
| Recall@8 | 89.9% | 90.6% | 93.7% |
| MRR | 0.665 | 0.679 | 0.704 |
| candidate absent from list | 2.1% | 1.2% | 1.2% |
| empty list | 0.2% | 0.2% | 0.2% |
| incorrect insertions (chosen candidate) | 12 / 1,742 (0.7%) | 0 / 1,757 | 0 / 1,757 |
| invalid candidates (jackson-core) | 4 / 166, harness artifact, see below | 0 / 162 | 0 / 162 |

"Before" is the same harness on the code without this work (measured by reverting the changed source files).
**Correction (see "Independent validation"):** the "before" column above has no statistics, so its comparison with the
"after, with statistics" column mixes two settings. Like for like (statistics on both sides) the development gain is
Recall@1 52.7% → 55.6%, Recall@8 92.7% → 93.7%, MRR 0.681 → 0.704. Per
context, with statistics on (R@1 / R@8 / MRR):

| context | sites | before (no stats) | after (stats) |
|---|---|---|---|
| local | 326 | 74.5 / 97.9 / 0.852 | 81.9 / 97.9 / 0.893 |
| field | 267 | 42.3 / 87.3 / 0.588 | 43.1 / 86.5 / 0.593 |
| method | 228 | 51.8 / 87.7 / 0.652 | 53.1 / 87.7 / 0.663 |
| static member | 95 | 70.5 / 98.9 / 0.812 | 70.5 / 98.9 / 0.812 |
| method chain | 17 | 52.9 / 94.1 / 0.695 | 52.9 / 94.1 / 0.695 |
| constructor (`new X`) | 57 | 43.9 / 57.9 / 0.486 (29.8% absent) | 52.6 / 93.0 / 0.697 (3.5% absent) |
| import | 100 | 52.0 / 95.0 / 0.690 | 67.0 / 98.0 / 0.801 |
| generic argument | 21 | 23.8 / 81.0 / 0.501 | 52.4 / 85.7 / 0.667 |
| type | 667 | 43.2 / 88.8 / 0.602 | 45.3 / 95.5 / 0.642 |
| lambda | 1 | 100 | 100 (too few sites to say anything) |

`broken-line` is within 0.2 points of `complete` on every row: the repair keeps completion intact when the rest of the
statement is gone. The "4 invalid" before came from the first version of the check swapping a method name into a
*field* position (`Integer.max` for `Integer.MAX_VALUE`); the check now compares like with like.

## What was wrong, and what changed

1. **Candidates missing after `new` with no expected type** (`throw new I▮`, `var x = new I▮`): the in-scope loop
   kept a class only if it matched the expected type, and with none, nothing matched, so `java.lang` and imported
   classes came only from the classpath search, which is capped. `IllegalStateException` was absent. Now every in-scope
   class is a candidate when there is nothing to filter by (`newExpressionUpdates`). Constructor absence 29.8% → 3.5%.
2. **Expected type for `throw`** (JLS 14.18): `throw new ▮` expects a `Throwable`, so exceptions lead (`JavaExpectedType`).
3. **Expected type applied to the head of a longer expression**: in `if (t▮ype == x)` the boolean expectation boosted
   `true` over the local `type` (+5). An expected type belongs to the whole expression, so it is dropped when the
   identifier is followed by `.`, `[`, a comparison or arithmetic operator or `instanceof`
   (`JavaExpectedType.continuesAsLargerExpression`, applied at the bare-identifier site only; member access is untouched).
   Local R@1 74.5% → 81.9%.
4. **Intersection bounds were intersected, not united**: `<X extends Number & Comparable<X>>` offered neither
   `compareTo` (second bound) nor, via the typer, anything beyond the first bound. javac accepts both
   (verified), JLS 4.9 says the union; the old code and a unit test said otherwise (`JavaMemberLookup`,
   `JavaExpressionTyper.typed`). One bound still types as that bound.
5. **Invalid insertion text**, now one pure function shared by the editor and the harness (`CompletionInsertion`):
   `new Foo▮<String>()` no longer gets a second `<>()`; `new Foo▮() {` no longer gets an anonymous body; a cast item
   `Number) ` is not written when `)` follows (12 bad insertions → 0). The snippet path now applies the same rules.
6. **Import completion ignored project usage**: members of a package in `import a.b.▮` now get the same capped
   usage nudge as other class lists. Import R@1 52% → 67% (statistics on).

Regression tests: 33 new golden corpus cases (`Quality*`, `SemGen*`, `Cap16…SecondBound`; 452/452 pass, ratcheted), `CompletionInsertionTests`
(5), the corrected `JavaMemberLookupTests.testIntersectionBoundUnitesMembers`, and the harness itself.

## Semantic audit: the cases that already worked

28 `SemGen*` cases probe receiver typing where the engine could plausibly fail; 25 passed untouched: wildcards
(`? extends`, nested, `? super`), inherited generics through one and two levels, stream and `computeIfAbsent`
chains, lambda parameters (one and two arguments, `Collectors.groupingBy`), method references, nested and inner
classes, static vs instance (`String.l▮` offers no instance members), overloads by argument type, generic-method
inference, `Optional.map`, ternary, array element, `var`, record accessors, casts, pattern bindings, enhanced-for.
The three failures were two mistakes in my cases and the intersection bug above.

## Performance

`PerfHarness java-completion synthetic`, release, same session, original files swapped back in for the "before"
(medians, ms): member access 0.205 → 0.207, lambda chain 0.581 → 0.583, class name (1 char) fast/final 0.73/2.11 →
0.72/2.11, `new` with expected type 1.057 → 1.058, statement 0.198/0.360 → 0.201/0.367, 5,000-line file member access
11.38 → 11.37, typing 0.767 → 0.757. A second "after" run agreed within 1%. All three budgets pass. Real-project
first-draw latency was **not** re-measured (the projects behind the baseline's table are not on this machine); the
changes add one forward scan of an identifier's length per statement-site request and in-scope class stubs to the
`new` path, which the synthetic `new` case exercises.

## Remaining limitations

- **Sample size and coverage.** *Superseded:* the first pass used two libraries (1,779 sites). The held-out
  evaluation below adds six projects (5,024 scored sites), including a multi-module Gradle project.
  An earlier claim that Spring/Gradle projects "were not available" was wrong: Umbra's cached Gradle models were on this machine.
- **Not held out.** *Superseded by the held-out evaluation below.*
- **R@1 is capped by the oracle.** Field 43%, method 53%, type 45%: the remaining misses are mostly equally valid
  siblings (`toLowerCase` vs `trim`, `getAsInt` vs `getAsNumber`). Usage statistics help types and imports; there are
  no member statistics (a deliberate earlier decision, `docs/audit/findings/F18-ranking-statistics.md`).
- **Statistics are optimistic here**: the harness's counts include the file under test, as the app's name index does.
- **Not built**: ranking a not-yet-imported type the current file already mentions; an expected type for `var`
  initializers; tie-break between enum constants (`BOOLEAN` before `BEGIN_ARRAY`: shorter label wins); generic-argument
  context has no signal beyond statistics (R@1 24% without them).
- **Insertion**: only the developer's candidate is checked, by parsing. Postfix/snippet templates, static imports,
  fully-qualified names and method-reference insertion are covered by corpus cases, not by this measurement.
- **Incomplete code**: one shape measured (rest of line deleted). Unclosed lambdas and half-written generic arguments
  are exercised by existing `Err*` corpus cases, not by the metric.
- **JDK**: measured on JDK 25. The differential baseline (JDK 27) was not rewritten; its comparison skips on a
  version mismatch.


# Independent validation

Question: do the improvements generalize to projects nothing was written against, and is the editor integration
correct? The implementation was frozen before the held-out measurement (no ranking change followed it). Two
bugs it found were fixed afterwards, and are listed as such. Reproduce with `JAVA_QUALITY_SET=held-out|development|all`
(`JAVA_QUALITY_GRADLE=a,b` picks Umbra's cached Gradle models by directory name). "Before" is the same harness, built
in a separate `git worktree` at `HEAD` (which already contained the earlier uncommitted work), with the pre-change
insertion rule, so nothing in the working tree was reverted. Statistics on for both sides. 1-character prefix, JDK 25.

## Held-out projects

commons-collections 4.5.0 and jOOL 0.9.15 (public; heavy generics and deep hierarchies, no dependencies), and four
Gradle projects Umbra had synced: a 6-module Spring-style service (337 jars), a gateway service (178 jars), a 3-module
library, a migration tool. They were never opened during development. Source sets, jars and the Lombok processor path
come from the cached Gradle model, as in the app. 30 stride-sampled files and up to 60 sites per file per project.
Development (gson, jackson-core) and held-out numbers are never merged.

| held-out, 5,024 scored sites | before | after |
|---|---|---|
| Recall@1 | 64.3% | 68.9% |
| Recall@3 | 83.4% | 85.5% |
| Recall@8 | 91.9% | 92.8% |
| MRR | 0.749 | 0.783 |
| expected candidate absent | 2.9% | 2.3% |
| empty list | 0.3% | 0.3% |
| duplicates in the top 8 | 0.0% | 0.0% |
| incorrect insertions (chosen candidate parses) | 63 / 4,877 (1.3%) | 0 / 4,908 |
| invalid alternatives, with validation coverage | 4 / 755 at 82.8% (670 of 809 eligible) | 4 / 755 at 82.8% |
| files compile cleanly as-is | 73 of 180 | 73 of 180 |

By context (R@1 / R@8 / MRR), before → after:

| context | sites | before | after |
|---|---|---|---|
| local | 824 | 89.0 / 99.0 / 0.934 | 91.3 / 99.0 / 0.949 |
| field | 430 | 71.6 / 95.8 / 0.813 | 73.5 / 96.0 / 0.828 |
| method | 601 | 56.4 / 88.0 / 0.688 | 56.4 / 88.0 / 0.688 |
| static member | 247 | 83.0 / 96.8 / 0.882 | 83.0 / 96.8 / 0.882 |
| method chain | 143 | 54.5 / 94.4 / 0.695 | 54.5 / 94.4 / 0.695 |
| constructor | 125 | 66.4 / 73.6 / 0.691 (26.4% absent) | 83.2 / 97.6 / 0.888 (1.6% absent) |
| import | 442 | 44.6 / 95.9 / 0.623 | 75.6 / 98.6 / 0.845 |
| generic argument | 208 | 35.1 / 85.6 / 0.539 | 35.1 / 85.6 / 0.539 |
| lambda | 184 | 84.2 / 98.4 / 0.909 | 84.2 / 98.4 / 0.911 |
| type | 1,820 | 58.2 / 88.6 / 0.699 | 60.8 / 88.6 / 0.716 |

Every project improved: Recall@1 (before → after) commons-collections 64.6 → 70.9, jOOL 61.8 → 68.2, mongomigrator
61.3 → 64.7, gateway 65.5 → 70.4, 6-module 62.4 → 64.6, 3-module 69.5 → 73.0; MRR rose by 0.018 to 0.053 in each.
Contexts the work did not touch (method, static, chain, generic) are unchanged to the digit, as they should be.
The intersection-bound fix has no measurable effect here (the shape is rare); it is covered by corpus cases and javac.
On files that compile cleanly as-is (2,072 sites): 66.4 / 85.6 / 92.7 / 0.769 → 71.7 / 89.2 / 94.4 / 0.812.
Broken-line variant (rest of the statement deleted), after: 66.5 / 84.1 / 91.5 / 0.763; the gap to `complete` is
2.4 points of Recall@1 (development: 1.4), so incomplete code costs a little more on the larger projects, most in
chains (49.7 vs 54.5) and generic arguments (33.2 vs 35.1).

Development, like for like (statistics on both sides, 1,779 sites): Recall@1 52.7 → 55.6, Recall@3 81.2 → 82.9,
Recall@8 92.7 → 93.7, MRR 0.681 → 0.704. Constructor Recall@8 66.7 → 93.0, absent 29.8% → 3.5%, bad insertions 12 → 0.
The held-out gains (+4.6 Recall@1) are not smaller than the development gains (+2.9): the fixes are not fitted to gson
and jackson-core.

## Receiver-fidelity change (JDK 27, ranking weights unchanged)

Measured after the scope and overload-applicability fixes in `docs/JAVA_GENERIC_TYPE_AUDIT.md`. Same harness,
`JAVA_QUALITY_SET=all JAVA_QUALITY_STATS=1`, prefix length 1. This is JDK 27. The table above is JDK 25, and the
held-out project set is not the same one (sxb-product scored 0 sites here: every oracle attribute request failed, so
it is absent from the aggregate). Do not read the two tables as one A/B.

Development, 1,779 scored sites (the same count as the JDK 25 row): Recall@1 56.0 %, Recall@3 83.3 %, Recall@8 94.2 %,
MRR 0.708, empty 0.2 %, incorrect insertions 0 / 1,766, invalid candidates 0 / 281 with validation coverage 240 / 240.
The JDK 25 "after" row was 55.6 / 82.9 / 93.7 / 0.704.

Held-out, 3,676 scored sites over commons-collections, jOOL, sxb-agent, Balatro4j, and sxb-conciliator:

| | R@1 | R@3 | R@8 | MRR | empty | insertions | invalid (coverage) |
|---|---|---|---|---|---|---|---|
| complete | 67.5 % | 86.2 % | 92.0 % | 0.774 | 0.4 % | 0 / 3,551 | 0 / 522 (448 / 451 = 99.3 %) |
| broken line | 65.0 % | 84.8 % | 91.1 % | 0.755 | 0.4 % | — | — |
| files that compile | 68.7 % | 90.5 % | 95.0 % | 0.796 | 0.0 % | 0 / 1,210 | 0 / 171 |

Member completion on that held-out set (R@1 / R@8 / MRR): field 71.9 / 97.2 / 0.833, method 61.1 / 86.8 / 0.718,
static member 75.3 / 94.7 / 0.826. Inherited interface fields are covered by the receiver audit (`field-path` exact
100 %) and by `JavaMemberLookupTests/testInterfaceFieldHidingAndSiblingAmbiguity`; this harness did not change
ranking, so a field that is ambiguous between sibling interfaces is omitted rather than ranked.

Release A/B against `HEAD` (`java-completion synthetic`, `java-scope-tree synthetic --lines 2000`,
`java-allocations synthetic --samples 3`), three alternating rounds for completion and the scope tree, two for
allocations. Final-update medians, before → after: member access 0.118 → 0.121 ms, a prefixed member 0.138 → 0.142 ms,
generic invocation 0.491 → 0.520 ms, member access in a 5,000-line file 6.78 → 6.81 ms. Scope-tree construction on
2,004 lines 4.63 → 4.80 ms. One 5,000-line completion allocates 342.1 KB (686 allocations) before and 343.6 KB
(695) after. At 120,000 lines both sides allocate 4.95 MB. The extra allocations do not scale with the file.

## Oracle reliability

Expected candidate = the developer's choice at a site where javac resolves the identifier to a symbol of the same
name. Audit of what is left out, held-out set, 9,276 sampled sites (nothing else is dropped: 9,276 − 1,837 − 1,728 −
687 = 5,024):

| excluded | sites | why |
|---|---|---|
| package segment | 1,837 | `java` in `java.util.List`: nothing to complete |
| declaration name | 1,728 | naming something new has no expected candidate |
| javac resolved no symbol | 687 (7.4%) | mongomigrator 475 (26.5% of its sites), 6-module 192 (12.4%), 3-module 19, jOOL 1 |

The "no symbol" exclusion is the one that could hide difficult sites: it is concentrated in two projects where
javac cannot see all dependencies, so those sites are the ones the oracle cannot judge, not necessarily hard ones.
Oracle health varies by project: gateway and commons-collections compile cleanly (30/30, 29/30 files); jOOL has
2/30 clean files but only JDK 25 generic-inference errors, which do not block attribution; mongomigrator has 0/30
(`doesnt.exist`, `cant.resolve`: the model's jars do not give javac a complete classpath), the 6-module project 7/30, the
3-module library 5/30 (`package.not.visible`: it has a `module-info`). The clean-file subset above is the safer headline;
results on mongomigrator and the 6-module project should be read with that in mind (their Recall@8 stays at
92.3% / 92.4%, so they are not worse than the others).

What the oracle does not distinguish: overloads (a candidate matches by name, so any `substring` counts), and it
cannot tell a better choice from the developer's choice. Recall is a lower bound on usefulness, and the ceiling for
Recall@1 at one typed character is far below 100%. The expected candidate for a constructor is the class name.
The tail of the identifier (and, for `broken-line`, the rest of the line) is deleted, which changes the statement; the
`complete` variant keeps the surrounding code, so recall there is the more direct measure.

## Invalid-candidate detection and coverage

A site is validated only if a negative control (the name `zzNoSuchMember` written at the site) is reported by javac,
as an error ending exactly at the swapped name. A candidate is invalid only if its own swapped name is rejected
at that position. (The first version counted any new error in the file and flagged 25 of 710: a different method written
mid-chain can break the *next* member, which is the chain's error, not the candidate's. Fixed.)

| set | eligible sites | validated | coverage | alternatives checked | invalid |
|---|---|---|---|---|---|
| development | 271 | 271 | 100% | 326 | 0 |
| held-out | 809 | 670 | 82.8% | 755 | 4 (0.5%) |

Per held-out project (validated / eligible): commons-collections 148/148, jOOL 73/73, gateway 200/200, 3-module
library 157/157, mongomigrator 29/69 (42%), 6-module project 63/162 (39%). All 139 unvalidated sites are
`compiler-setup` failures (missing classpath or module). Zero results elsewhere must be read against these
denominators, and no semantic-validity claim is made for the 6-module project or mongomigrator.
Gson, which the first pass could validate at only 120 of 240 controls, now validates 150/150: `module-info.java`
made javac stop at `module.not.found` before attributing anything, so the oracle compiles a copy without it.

The 4 invalid candidates: 3 are a real engine defect in jOOL (`Agg.java`, `(l, v) -> { if (l.size() < n) ... }`):
`l`'s type is bound by the *other* lambda's return value (`() -> new ArrayList<T>()` in the same call), Umbra does not
infer it, and it offers `Seq` methods (`skip`, `slice`, `sorted`) where `size` belongs; `size` itself is absent.
The fourth is in a private project and has not been analyzed.

## Editor insertion, through the real controller

`JavaCompletionControllerTests.testAcceptingAnItemWritesWhatTheHarnessPredictsAndPlacesTheCaret` drives a real
`TextView` + `EditorIntelligenceController` + `CompletionEngine` + Java provider, requests completion with the caret
mid-line (text after the caret stays, as when editing existing code), selects an item and accepts it, then asserts the
final document, the caret offset, that the quality harness's prediction (`apply`) is the same document, and the
parse. 18 scenarios, all passing: constructor with existing parentheses (caret inside them), with existing type
arguments, generic constructor before `(`, anonymous class before `(` and body, cast with `)` already present, method
with existing parentheses / none (with and without parameters), method reference, overloaded static method with
existing arguments, nested class, non-ASCII text (emoji, accents) before the caret, incomplete statement, unclosed call,
constructor with an import added, static member with `import static` added (opt-in policy), annotation attribute with
` = ` already written and with nothing written. Unit tests in `CompletionInsertionTests` (7).

Found by this validation, fixed, and covered by tests: (1) annotation attributes were inserted as `value = ` before an
existing ` = ` (`value =  = "x"`; after the first-pass fixes these were the 8 incorrect insertions left on the held-out projects, of 63 before; none on development); (2) a plain
`new Foo▮(x)` lost the old caret placement inside the parentheses after my first insertion rule, found by review before
any run. Two behaviors worth knowing: an explicit request with exactly one candidate auto-inserts it without showing a
popup (that path was exercised: `text.length();`, `e.length();`, `value = "all"` all correct), and static-member
completion is off by default (`JavaImportPolicy.staticMemberClasses` is empty).
Not covered: Tab (`replacingIdentifier: true`), multi-cursor, postfix templates and live templates.

## Performance (same session, release, current tree vs `HEAD` worktree)

Synthetic provider medians (ms, before → after): member access 0.212 → 0.215, class name (1 char) fast/final
0.76/2.21 → 0.74/2.15, `new` with expected type 1.073 → 1.117, statement 0.204/0.369 → 0.193/0.369, 5,000-line file
member access typing 0.866 → 0.810, large file 11.96 → 11.82. Allocation per typing request: 325.2 KB / 680 → 325.7 KB / 680.
Name-index usage counts (the import-list lookup): 24 µs per 225 identifiers.

Real projects (`java-completion-latency project`, 8 samples per site): cold first draw sxb-gateway 31.4 → 36.6 ms,
6-module project 41.4 → 45.7 ms (two requests each); warm first draw 13.8 → 18.5 and 13.9 → 14.9 ms. The first
pair looked like a regression; three further alternating runs of the gateway project gave warm first draw 20.9 / 23.1
(before) and 21.4 / 21.7 ms (after), with run-to-run spread (about 9 ms) larger than any before/after gap and the order
flipping, so the data show no detectable change and no way to detect one smaller than the drift. Re-measured on an idle machine, three alternating synthetic runs per tree (final-update medians, ms; before / after):
`new` with expected type 1.099, 1.131, 1.160 / 1.124, 1.323, 1.200 (median 1.131 → 1.200, +6%); class name (1 char)
2.165, 2.358, 2.365 / 2.279, 2.637, 2.420 (median 2.358 → 2.420, +3%); member access 0.215, 0.212, 0.214 / 0.212, 0.215,
0.216 (flat); statement 0.376, 0.410, 0.678 / 0.367, 0.385, 0.387 (no worse). So two of the four paths are about
0.07 ms (`new`) and 0.06 ms (class name) slower in the median, with overlapping ranges (one 1.323 outlier after). That is
small beside the budgets (50 ms first update, 150 ms final) and could be noise, but it is **not** shown to be zero,
and the data cannot say which change would cause it: the `new` case runs with an expected type, where the new in-scope
branch is not taken. If it matters, bisect the four source changes with `java-completion synthetic` before keeping all of them.

## Tests

- Java completion corpus: 452 cases, all passing, ratcheted. `Scripts/ci-java-tests.sh`: 153 tests, 0 failures.
- Controller suite (`JavaCompletionControllerTests`, 18 tests) and `CompletionInsertionTests` (7): all pass.
- Full root suite: 5,251 tests, 24 skipped, 9 failures. Eight are the pre-existing failures the baseline document lists
  (4 `JavaGoToImplementationTests.testDefinitionOnConcreteOrStaticDeclarationsStaysEmpty` assertions, 2
  `RecentFilesSwitcherTests`, 2 JaCoCo `JavaInstrumentationRealJDKTests`). The ninth, `JavaScopeTreeTests.testLargeFileBuildsQuickly`
  (a debug-build timing guard of 1.0 s on a component this work does not touch), failed at 1.2 s in the full run, again in
  isolation at 1.5 s, passed at 1.05 s once, and fails at 4.3 s in the untouched `HEAD` worktree: a timing flake, not caused by
  these changes. No test related to Java completion, insertion or the quality harness fails.

## Remaining semantic weaknesses (evidence-based)

1. **Lambda parameter bound by another lambda's result** in one generic call (jOOL above): wrong receiver, wrong
   candidates, expected one missing. The only defect the validity metric found.
2. **Generic arguments** (`List<▮>`): Recall@1 35%, absent 8.2% held-out (13% under `broken-line`); no signal beyond usage.
3. **Methods and fields**: Recall@1 56% / 74%; siblings with equal prefix match are separated only by statistics,
   which exist for classes but not members (a documented earlier decision).
4. **Field/method completion in incomplete chains**: `broken-line` loses 5 points on chains.
5. **Oracle coverage on projects with a `module-info` or incomplete model classpath** (3-module library, mongomigrator,
   6-module project): the harness cannot validate candidates there; applying the module-info mirror to Gradle projects
   needs path mapping and is not done.
6. **Unmeasured**: Tab-accept, multi-cursor and postfix/live-template insertion; private-project invalid candidate
   (1) not analyzed; Spring Boot code is represented by the gateway and the 6-module service, not by a public project.

## Recommendation

Keep the changes, with one open item (the small `new`/class-name latency difference above). They improve every one of six unseen projects on every headline metric, the gain is not smaller than
on the development projects, the editor writes exactly what the harness predicts in 18 real-controller scenarios,
no incorrect insertions remain in 4,908 held-out sites, allocations are identical, and member-access, statement and large-file latency are flat; `new` and class-name completion are 3-6% (0.06-0.07 ms) slower in the median, within overlapping ranges. Conditions: do not cite the first pass's 51.8% → 55.6% (it mixed settings); read the zero-invalid results with the
coverage denominators above; and treat lambda inference across several lambdas of one generic call as the next semantic gap.


# Contextual inference for lambdas and generic calls

The open item above ("lambda parameter bound by another lambda's result") was the only defect the validity
metric found. This section is its root cause, an audit of what the engine infers, the change, and how it was
checked. Code: `Sources/JavaIntelligence/Semantics/JavaExpressionTyper.swift` (`inferInvocation`, `infer`,
`applyFunctional`, `resolveOverloads`). Specification: corpus cases `Lam*` (83 cases, 81 pass, 2 documented gaps).

## Root cause of the jOOL failure

`Agg.taking` in jOOL 0.9.15:

```java
return Collector.of(
    () -> new ArrayList<T>(),
    (l, v) -> { if (l.size() < n) l.add(v); },
    (l1, l2) -> { l1.addAll(l2); return l1; },
    Seq::seq);
```

1. **Signature.** `Collector.of` has two overloads that take four arguments here:
   `of(Supplier<R>, BiConsumer<R,T>, BinaryOperator<R>, Characteristics...)` and
   `of(Supplier<A>, BiConsumer<A,T>, BinaryOperator<A>, Function<A,R>, Characteristics...)`.
2. **Functional interface at the caret.** `BiConsumer<A,T>`. `A` is bound by nothing but the *supplier lambda's
   return value* (`ArrayList<T>`); `Seq::seq` is the finisher.
3. **Where substitution was lost, three independent defects.**
   - *Overload chosen by parameter count.* The lambda-parameter query kept overloads whose parameter count equals the
     argument count: the 4-parameter overload won, so `Seq::seq` sat in the `Characteristics...` slot. Nothing asked
     whether a method reference can be passed to an enum array at all.
   - *Target type won over everything.* The enclosing `return` supplies `Collector<T,?,Seq<T>>`; against the wrong
     overload's `Collector<T,R,R>` that bound `R := Seq<T>` before any argument was looked at.
   - *Sibling lambdas contributed nothing.* The query bound type variables from plain arguments only, so the supplier's
     `ArrayList<T>` was never used even on the right overload.
4. **Receiver.** Not unresolved: wrongly *substituted* (`Seq<T>`). A wrong binding looks exactly like a right one.
5. **Why unrelated members.** They were the members of `Seq<T>` (`skip`, `slice`, `sorted`, `crossJoin`…), valid
   members of a type the variable does not have; `size` is not one of them. javac attributes `l` as `ArrayList<T>`.

Reproduced on the real source (`JavaLambdaContextInferenceJOOLTests`) and independently by the quality harness:
`method skip/slice/sorted instead of size in jOOL/Agg.java@3488`.

## Capability audit

| Area | Before | Now |
|---|---|---|
| Explicit type arguments | applied | unchanged |
| Plain-argument constraints, several args meet in their lub | applied | unchanged |
| Target type | bound first, equality for every shape | type arguments as equality; a *bare* return variable (`<R> R f(…)`) is an upper bound only, so it is applied after arguments and lambda results (JLS 18.4), but before an input is defaulted |
| Overload applicability for lambdas / method refs | argument count only (query), "unknown is compatible" (call typing) | JLS 15.12.2.1 potential compatibility: functional interface with the lambda's arity, or a method type variable |
| Result of another lambda / method reference | used when typing the call, **not** when typing a lambda parameter | shared by both: one routine (`inferInvocation`) |
| Order of lambdas | argument order, inputs typed even when unresolved | pertinent ones first (zero-arg, explicit, method refs), implicit ones when their inputs are known, last ones with inputs resolved to their bounds |
| Explicitly typed lambda parameters | ignored | bind the interface's parameter types |
| Method reference inputs | only the result | `Type::instanceMethod` binds the receiver (when `Type` is complete without type arguments); the single static method of that arity binds its parameters |
| Callee `<T>` vs the caller's own `<T>` | one variable (bound by name) | callee type parameters renamed apart (`T#`); in-scope type variables are real types |
| `T[]` against `User[]` | not applicable, so `Stream.of(users)` was `Stream<User[]>` | applicable; a primitive array still is not |
| Wildcards, intersection bounds, nested generic calls | handled | unchanged |

Defects by kind: *incorrect substitution* (target priority, name capture), *missing constraint* (sibling lambda
results, explicit lambda parameters, method reference inputs), *unresolved overload* (count-only applicability,
`T[]`), *parser recovery* (below). Not an inference defect: none of the remaining failures.

## Design

One inference routine for the call (`inferInvocation`), used by `typedMethodInvocation` (the call's own type) and by the
lambda-parameter query (`functionalTargets`), which differs only in leaving the asked-about lambda out: its body holds
the caret and is usually unfinished, so it must not constrain itself. No solver: a single pass in javac's order with a
bounded retry loop over the lambdas (at most one round per lambda), deterministic first-wins bindings, and the old
behaviour as the fallback (a parameter nothing could type is `Object`).

**Bounds.** A lambda parameter used inside sibling lambdas of nested calls asks its own call the same question, and
each answer types those siblings. Measured on nests where every level names every outer parameter, the cost
doubled per level (depth 14: ~3 s in a debug build). A per-question memo (`LambdaParameterMemo`, scoped to the
outermost question) makes it linear (depth 14: 47 ms single, 11 ms sibling; `JavaLambdaInferenceBoundsTests`), and
a nesting cap of 8 stays as a backstop.

## Verification

- **Corpus.** 71 new `Lam*` cases state the receiver's *full* type (`//! receiverType:`; the older `receiver:`
  compares the erased name only and cannot tell `List<String>` from `List<Object>`). Before the change 53 of the 83
  `Lam*` cases pass (28 real failures, 2 gaps); after, 81 pass and the same 2 gaps remain. All 452 older cases
  still pass. The full corpus is 523 cases, 521 pass.
- **javac as oracle.** `JavaLambdaInferenceOracleTests` replaces the caret by a member that does not exist and reads the
  receiver out of javac's `cannot find symbol … location:`. Every case with a `receiverType` and no `oracle:` note
  (about 50) must agree with javac. That is how the expectations were written, not just checked. Cases with an
  `oracle:` note are excluded with a reason: unfinished code javac cannot parse (its complete twin is checked), and
  two cases where javac prints the variable `T` and the engine reports its single bound, as `Cap15BoundedTypeVar`
  already does.
- **The jOOL site itself.** `JavaLambdaContextInferenceJOOLTests` pins the original site: receiver `ArrayList<T>`,
  `size`/`add`/`addAll` offered, `skip`/`slice`/`sorted` not.
- Covered shapes: streams (`map`, `flatMap`, `reduce` two and three arguments, three-argument `collect`),
  `Collectors` (`toMap` with merge, `groupingBy`+`mapping`, `collectingAndThen`), `Comparator` (explicit parameter,
  method reference), `Function.andThen`, `BiFunction`, `BiConsumer`, `Map.forEach/merge/computeIfAbsent/replaceAll`,
  `CompletableFuture.thenApply/thenCombine`, user generic methods with one to three lambdas, wildcard and bounded
  type variables, overloads that differ by lambda arity or by a varargs enum, nested lambdas, incomplete bodies.

## Quality harness (Phase 5)

Same harness, same projects, `HEAD` worktree vs. the working tree, statistics on, 1-character prefix, JDK 27.
**Caveat on the held-out set:** the four Gradle models cached on this machine are not the four of the earlier
validation (`sxb-product` yields no scored sites; `sxb-agent`, `Balatro4j`, `sxb-conciliator` were not in it). Only
commons-collections and jOOL are the same. Absolute numbers therefore differ from the tables above; before/after is
like for like. Development (gson, jackson-core) is identical to the digit.

| held-out, 3,676 scored sites | before | after |
|---|---|---|
| Recall@1 / @3 / @8 | 66.9 / 85.5 / 91.2 % | 66.9 / 85.6 / 91.3 % |
| MRR | 0.768 | 0.768 |
| expected candidate absent | 4.2 % | 4.1 % |
| duplicates in the top 8 | 0.0 % | 0.0 % |
| incorrect insertions (chosen candidate parses) | 0 / 3,522 | 0 / 3,524 |
| invalid alternatives, validation coverage 99.3 % (448 of 451 eligible) | **3 / 506** | **0 / 505** |

The 3 invalid before are the defect above (`skip`, `slice`, `sorted` for `size`, jOOL `Agg.java@3488`).

By context (R@1 / R@8 / MRR), held-out aggregate. Only `method` moved:

| context | sites | before | after |
|---|---|---|---|
| lambda | 176 | 84.1 / 97.7 / 0.909 | same |
| method | 409 | 60.9 / 86.3 / 0.714 (5.6 % absent) | 61.1 / 86.8 / 0.717 (5.1 % absent) |
| method chain | 73 | 43.8 / 94.5 / 0.614 | same |
| field, static (ordinary member) | 363, 150 | 68.9 / 93.4, 75.3 / 90.7 | same |
| generic (`List<▮>`) | 83 | 49.4 / 85.5 / 0.646 | same |

jOOL alone, `method`: R@1 53.6 → 55.4 %, R@8 87.5 → 91.1 %, absent 3.6 → 0.0 %. The harness has no "generic
method call" context (`generic` means a type-argument position), and its metric is the developer's own identifier at a
one-character prefix, so it changes only where a wrong receiver hid the member. The 0 vs 3 invalid candidates and the
javac-checked corpus are the evidence that matters here; ranking weights were not touched.

## Performance (Phase 6)

`PerfHarness java-completion synthetic` (release, provider only), three binaries built from `HEAD~1` (before the
earlier quality work), `HEAD`, and this change, run alternately, six rounds each, medians of the final update in ms
with the min-max range over the six runs. Two new sites measure the paths this change touches
(`lambda_sibling`: `Collector.of(() -> new ArrayList<String>(), (l, v) -> l.▮ …)`; `generic_invocation`:
`Collections.max(users, Comparator.comparing(u -> u.▮))`).

**Conditions, honestly:** the machine was not idle. Load averages were 5-6 (a Discord helper at ~40 % CPU, and
`mediaanalysisd` in the earlier rounds), a first set of rounds ran at load 6-7. Absolute times are therefore
contended and this is a *paired* comparison, not a quiet-machine baseline. Within one binary the six runs differ by
1-3 %, which is the resolution.

| site | HEAD~1 | HEAD | this change | change vs HEAD |
|---|---|---|---|---|
| member access | 0.118 [0.116-0.128] | 0.118 [0.114-0.125] | 0.120 [0.115-0.127] | +1.3 % |
| member prefix | 0.139 | 0.139 | 0.141 | +0.7 % |
| class name, 1 char | 1.177 | 1.179 | 1.188 | +0.8 % |
| class name, 3 chars | 0.727 | 0.726 | 0.736 | +1.4 % |
| `new` with expected type | 0.562 | 0.564 | 0.565 | +0.3 % |
| statement | 0.204 | 0.204 | 0.206 | +0.7 % |
| 5,000-line file, member access | 6.611 | 6.762 | 6.694 | -1.0 % |
| 5,000-line file, typing | 0.471 | 0.466 | 0.472 | +1.2 % |
| lambda chain (`filter(u -> …).map(u -> u.▮)`) | 0.343 | 0.346 | 0.352 [0.339-0.362] | +1.7 %, ranges overlap |
| generic invocation | 0.583 | 0.581 | 0.500 [0.495-0.531] | **-13.9 %** |
| lambda parameter bound by a sibling lambda | 0.284 | 0.281 | 1.367 [1.338-1.447] | **+1.09 ms** |

- **Ordinary typing is unchanged**: member access, prefix, class names, `new`, statement and the large file are
  within ±1.7 % and inside the run-to-run spread. The inference only runs when the caret is in a lambda whose
  parameter is being asked for.
- **The earlier "3-6 % slower `new` and class-name" item did not reproduce.** `HEAD` vs `HEAD~1`: `new` +0.2 %,
  class name -0.2 % to +1.4 %, over six alternating rounds. At this load that does not prove there is nothing under
  ~2 %, but the earlier gap (0.06-0.07 ms) is not visible, and `new` is +0.3 % between `HEAD` and this change.
- **`lambda_sibling` is slower because it now does the work.** It used to answer in 0.28 ms with the wrong
  receiver; correct inference reads two `Collector.of` overloads, the functional interfaces, the supplier's result
  and the method reference. 1.4 ms against budgets of 50 ms (first) and 150 ms (final).
- **The first version of this change cost `lambda_chain` +8-10 %** (~30 µs): the functional interface's signature was
  read twice per lambda and the memo key was built by interpolating an enum. Both were removed; the figure above is
  after them. Why `generic_invocation` got 14 % faster was not investigated (the old query bound every
  arity-matching overload; this one resolves overloads first).
- **Allocation per typing request** (`java-allocations synthetic`, member access): 325.2 KB / 680 allocations
  before, 341.6 KB / 683 after at 5,000 lines (934.5 → 950.8 KB at 20,000). A constant +16 KB, three allocations, in
  the 4 KB+ class, independent of file size: most likely a larger async frame for the inference function, not
  investigated further.
- The nested-lambda stress (`JavaLambdaInferenceBoundsTests`, debug build, depth 14): 47 ms single-lambda nest,
  11 ms sibling nest, against ~3 s each without the memo.

## Limitations

- ~~**A lambda block opened and never closed** still types the parameter `Object`.~~ *Superseded:* see "Inference
  while the code is incomplete" below; the one-line and the single-level multi-line forms are fixed, the doubly
  nested multi-line form is the remaining gap (`gap: R2`).
- ~~**Block bodies are not looked at for applicability**~~ *Superseded:* a *finished* lambda body now selects between
  `void` and value interfaces (`Consumer` vs `Function`, `Runnable` vs `Callable`); an unfinished one stays
  compatible with both. A block lambda's result is still its first `return`.
- No inference-variable bounds (`T extends Comparable<T>` is used only as the fallback for an unbound input), no
  capture conversion, no generic method references, no `lub` of several returns.
- `Characteristics...`-style rejection relies on `functionalSignature`, which takes the first abstract method: a
  non-functional interface passed a lambda is still "potentially compatible", as before.
- ~~The corpus ratchet (`baseline.json`) is bound to JDK 25 and skipped on any other JDK.~~ *Superseded:* it was run
  on JDK 25 and the new cases are ratcheted (below).


# Inference while the code is incomplete

The previous section left one known failure: a lambda block that is opened and not closed
(`LamIncompleteBlockUnclosed`, `LamIncompleteLaterArguments`) typed its parameters `Object`. This section traces both,
compares recovery strategies, and records what was changed. Code: `Completion/JavaCompletionRepair.swift`
(`closingSequence`), `Semantics/JavaLocalVariable.swift` (`recoveredCallArgumentTarget`),
`Semantics/Model/JavaScopeTree.swift` (`buildLocalVariables`), `Semantics/JavaExpressionTyper.swift` (`lambdaBody`).

## Root cause: three different places, not one

Each failure was traced through source text, repair output, tree-sitter tree, locals, call discovery, target typing,
receiver and candidates. The first point where context is lost differs:

| Case | What the tree is | First point of loss |
|---|---|---|
| `build(s, (l, v) -> { if (l.` (one line) | repaired to `…{ if (l.__penumbra__));`: the second `)` closes the call while the lambda block is open. Tree-sitter keeps both `lambda_expression`s but flattens the call into an `ERROR` of `identifier, lambda, lambda`: no `method_invocation`, no `argument_list` | **lambda target discovery** (`JavaExpressionTarget.target(of:)` accepted only a lambda under an `argument_list`), caused by the **repair text** |
| `pipe("x", s -> s.length(), n -> { n.` | repaired to `…{ n.__penumbra__);`: no lambda node exists at all, `n.__penumbra__` is an `ERROR(scoped_type_identifier)`, no locals | the **repair text** (the `)` is placed before the `}` it needs) |
| `String r = flag ? pipe("x", s -> s.length(), n -> n.` | repair is fine; the call and lambdas are well formed, but inside an `ERROR` that is a *child of the declaration, beside the declarator* | **scope construction**: `buildLocalVariables` only scoped each declarator's `value`, never the `ERROR` remnant |
| `build(s, (l, v) -> {` + newline + `l.` (no closer anywhere) | repair cannot help (the caret line has no brackets); same flattened `ERROR` as the first row | **lambda target discovery** |

Not responsible in any case: generic substitution, overload selection, receiver typing. Once the lambda had a correct
target they worked unchanged.

## Strategies compared

- **A, recover the lambda's context from the existing tree.** Works for rows 1 and 4 only if the call is rebuilt from
  the flat `ERROR` children, and cannot work for row 2 (no lambda node exists). It also depends on the shape tree-sitter
  happens to recover into.
- **B, repair the text.** One scan of the caret line that the repair already does. Closing a brace is the risk: global
  brace insertion changes every request. So only a `{` that follows `->` or `)` **and sits inside a `(` still open on
  that line** is closed (`;}` before the call's `)`), in nesting order. A block that stands on its own (`if (a) { foo.`)
  is not touched, nor an array initializer or a brace in a string. Fixes rows 1 and 2; a line without `{` takes the old
  path. Measured reach: the rule fires at 8 of 1.02 million identifier positions in 872 source files.
- **C, scan the text for the enclosing call, leave the repaired text alone.** The only strategy that helps row 4
  (nothing on the caret line to repair).

Chosen: **B for rows 1-2, plus a bounded form of C for row 4 and the `ERROR` remnant for row 3.** C reads only the
damaged region's bytes (statement start to the lambda, at most 4 KB), only when a lambda's parent is an `ERROR`, and
rebuilds `callee(earlier arguments, <parameters> -> {})`; a clean tree never reaches it. A was rejected.

## What changed

1. `JavaCompletionRepair.closingSequence` replaces the count of unclosed `(`: `)` for each, `;}` for a body brace nested
   in an open `(`. The `;` ends the statement under the caret (`if (c) ;` is valid; in a class body `;` is an empty
   member). `ReferenceRepair` (the equivalence oracle) was extended separately, in its own simple style.
2. `JavaExpressionTarget.recoveredCallArgumentTarget`: the call of a lambda under an `ERROR`, from the bytes. Skips
   strings, characters and comments; reads `a.b(c).<T>d(` callees; refuses `new X(` and anything where the innermost open
   bracket is not a `(`.
3. `buildLocalVariables` scopes the lambdas in a declaration's `ERROR` remnant.
4. **Finished lambda bodies select overloads** (the "incomplete block-bodied lambdas" limitation). JLS 15.27.2: a body
   is `void`-only, value-only or either. Applied to every lambda except the one holding the caret and any body that has a
   syntax error or contains the dummy identifier, which stay compatible with all overloads (an unfinished body must not
   exclude the overload being typed towards). `each(s -> { return s.length(); })` picked `Consumer` (receiver `void`),
   javac picks `Function`.
5. Test infrastructure: the corpus loader trimmed `.whitespaces`, leaving the `\r` of a CRLF case on the directive.

## Verification

- **Corpus**, every `Lam*` case, previous task's exact state vs now: **101 → 123 of 124** (the 124th is a documented gap).
  `LamInc*` (41 incomplete-code cases): **20 → 40**. `LamShape*` (7): 5 → 7. The rest of the corpus is unchanged:
  564 cases on JDK 27 and on JDK 25, 563 pass, 1 gap.
- **Shapes covered**: unclosed lambda blocks (call argument, local initializer, nested `if`, explicit first parameter,
  Unicode, CRLF), nested lambdas on one line, nested anonymous classes, a lambda inside an anonymous class inside a
  lambda, unclosed and nested `forEach`/stream chains, missing closing parentheses, an unfinished conditional, a call
  missing later arguments, explicit type arguments, partially typed chains and `Collectors`, constructor completion
  inside an unclosed lambda, and the same shapes with the closers already present below the caret (the usual state).
- **javac as oracle for unfinished code.** `//! oracle-completion: <text>` is what is compiled in place of the caret
  (for example `zzProbe(); });`), so javac attributes the very code being typed. `JavaLambdaInferenceOracleTests`
  checks all 108 cases that state a `receiverType` (40 of them with an `oracle-completion`), now also under JDK 25's javac.
- `JavaRecoveredLambdaTargetTests` (7): what the recovery rebuilds, what it refuses, and that a clean call is untouched;
  each asserts the lambda really is under an `ERROR`, so a grammar change cannot make it pass vacuously.
- `JavaRepairedTextEquivalenceTests`: the new closers against the independent reference at every caret of generated
  text (a counter asserts the generated text reaches the new branch), plus spelled-out expectations including CRLF and
  non-ASCII on the caret's line. Two controller scenarios (`unclosed lambda block`, `unclosed nested lambda blocks`):
  the editor writes what the harness predicts.
- **Ratchet on JDK 25.** `JAVA_HOME` = JDK 25: the committed baseline is enforced and holds; the baseline was then
  regenerated **on JDK 25** (+111 cases, 0 removed, `jdkVersion` unchanged at 25), never on 27.
- Suites: `Scripts/ci-java-tests.sh` 153 / 0 failures; controller and insertion tests 25 / 0; full root suite 5,263
  tests, 6 failures, all the pre-existing ones (`JavaGoToImplementationTests` 4 assertions, `RecentFilesSwitcherTests` 2);
  Umbra suite 2,834 tests, 15 failures in 8 tests that fail identically on untouched `HEAD`. One Umbra run hung for
  hours in `IDEAgentCheckpointBlobsTests` (0 % CPU) and was stopped; the rerun completed in 541 s with that test passing.

## Real-project quality harness

Same harness and projects as above, previous task's tree vs this one: **all 120 context rows identical in both variants**
(`complete` and `broken-line`); held-out 3,676 sites, R@1 66.9 %, R@8 91.3 %, MRR 0.768; invalid candidates 0 / 505,
incorrect insertions 0 / 3,524, duplicates 0.0 %. This is not evidence of benefit: the harness cannot reach the case.
Real code puts a lambda body on its own lines, so the caret line almost never has an open `{` inside an open call;
counted over 1.02 million identifier positions the new closers fire at 8. It is evidence of no regression, and the
small reach is also why the blast radius on existing behaviour is small. The benefit shows in the corpus above, which
is what the developer sees at the moment of typing a lambda inline.

## Performance

`java-completion synthetic`, release, six alternating runs of the previous task's binary and this one, medians in ms
[min-max]. Load average steady at 2.5 (better than last time's 5-6, still not idle); spreads are under 3 %.

| site | before | after |
|---|---|---|
| member access | 0.118 [0.116-0.123] | 0.117 [0.115-0.131] |
| member prefix | 0.142 | 0.137 |
| class name, 3 chars | 0.740 | 0.732 |
| `new` with expected type | 0.567 | 0.566 |
| statement | 0.206 | 0.209 |
| 5,000-line file, member access / typing | 6.816 / 0.478 | 6.784 / 0.474 |
| lambda chain | 0.345 | 0.351 |
| lambda parameter bound by a sibling lambda | 1.385 | 1.381 |
| generic invocation / nested generic invocation | 0.512 / 1.179 | 0.517 / 1.183 |
| **unclosed lambda block, one level** | 0.110 | **0.295** |
| **unclosed lambda blocks, two levels** | 0.143 | **0.427** |

- Ordinary completion is unchanged (all within ±1.7 %, ranges overlapping). The new work only runs when the caret
  line has an open `{` inside an open `(`, or a lambda sits under an `ERROR`.
- The unclosed-lambda sites cost 0.2-0.3 ms more because they now **infer** (like the sibling-lambda site, 1.4 ms) where
  they used to give up at once with the wrong answer. Budgets: 50 ms first update, 150 ms final.
- Allocation per typing request: 341.6 KB / 683 allocations before, 342.1 KB / 686 after (+0.5 KB, +3), the same at
  20,000 lines.
- Worst-case inference depth is unchanged and bounded: 14 nested levels with every level naming every outer parameter
  take 47 ms (single) and 11 ms (sibling) in a debug build; the call recovery adds one pass over at most 4 KB per
  lambda under an `ERROR`.

## Remaining limitations

- **Doubly nested, multi-line, never closed** (`LamIncMultiLineUnclosedNested`, `gap: R2`): the *outer* lambda is not a
  node in the recovered tree, only loose tokens, so its parameter is not a local and the inner call cannot be typed.
  Fixing it means recovering lambda parameters from raw `->` tokens in the scope tree.
- The call recovery cannot see arguments after the lambda (they are not in the damaged region), and reads only the
  last 4 KB before the lambda (from a line start): a call that opens further back is not found and the parameters stay
  `Object`.
- An unfinished lambda body is compatible with every overload by design; two overloads that differ only by body shape
  stay ambiguous until the body is finished. A block that only `throw`s fits both, and javac's choice there (functional
  interface specificity) is not reproduced.
- Still absent: inference-variable bounds, capture conversion (`Future<CAP#1>` reads `Future<Object>`), generic method
  references, the `lub` of several `return`s.
- The shape the repair handles is the transient one: a developer typing a lambda inline. Once the file has its closing
  braces (the usual state) the old path was already correct, and the closers it adds are harmless (four corpus cases
  pin that).

