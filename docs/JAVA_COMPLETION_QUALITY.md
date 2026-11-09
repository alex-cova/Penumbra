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
