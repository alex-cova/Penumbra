# Java receiver-type fidelity: the last 10 mismatches

Status: investigation complete; three engine fixes and one getClass rule are in the working tree, uncommitted.
Companion documents: `docs/JAVA_GENERIC_TYPE_AUDIT.md` (the 87 → 10 pass this continues),
`docs/JAVA_COMPLETION_QUALITY.md`, `docs/JAVA_COMPLETION_BASELINE.md`, `Sources/JavaIntelligence/Semantics/CLAUDE.md`.

## A. Executive summary

**Result by the audit's unchanged rules: 87 → 10 → 9.** By an independent member-set check against javac (section D),
**0 of the 10 sites offer a wrong member list** after this change; before it, 2 of them offered no members at all.

Zero cannot be reached by the audit's own rules without one of the two things the task rules out, and it should not be:

* **8 sites (`CellExtractor`) are spelling only.** javac writes the class as `<anonymous CellExtractor>.CounterCell`;
  the engine's name is `CellExtractor.$Anonymous<hash>.CounterCell`. The harness strips qualifiers, which turns the
  engine's name into `CounterCell` and leaves javac's `<anonymous …>` prefix, so the strings can never match. javac's
  member set and the engine's are identical at all 8 (checked by name, by owner, and by the members javac makes
  accessible). Matching the string would mean rewriting the engine's identity into javac's display format or changing
  the normalization. Neither was done.
* **1 site (`AgentCreditServiceImp:93`) is javac error recovery.** jackson-core is missing from disk, so javac drops
  the `JsonProcessingException` alternative and prints the lub of what it could resolve. That shape depends on which
  jar is missing (section B). The engine now answers `Throwable`, the most specific type JLS 14.20 proves. Its member
  list is identical to the one javac's recovery type has, and with both jars present javac and the engine agree on
  `Exception`.

The work found **three genuine engine defects that the bucket counts did not show**, and fixed them:

1. **One anonymous member class had two identities in one request.** Named in the body (`CounterCell counter`), it was
   bound as a local class, `CellExtractor.$Local<start>.CounterCell`, owned by the top-level type. Reached through the
   anonymous class's field (`TreeMap<CounterCell, CounterCell>`), it was `CellExtractor.$Anonymous<hash>.CounterCell`.
   Each looked right on its own; where both met, as in `(c ? counter : cells.firstKey()).`, the lub fell to
   `Comparable` and **`count` and `idx` disappeared** (javac: `CounterCell`). The audit prints both as `CounterCell`,
   so it could not see this.
2. **Arrays had only `length` and `clone()`.** JLS 10.7 gives them every member of `Object` except `clone`, so
   `array.getClass()`, `equals`, `hashCode` and `toString` neither completed nor typed, and nothing chained after them
   typed either (the `AbstractLinkedList:1093` site).
3. **An incomplete multi-catch fell back to its first written alternative.** In the audited order the first
   alternative was the missing one, so `e.` offered nothing. In the mirror order (`SQLException | NotIndexed`) it offered
   `SQLException`'s own members, which the real lub need not have.

Plus a rule that is not a fix of the 10: `x.getClass()` is now `Class<? extends |T|>` (JLS 4.3.2), not the declared
`Class<?>`, without capture variables. The 38 `getClass()` sites that already shared javac's member list stay in their
representation bucket, and `getClass().cast(o)` is now typed.

**No previously exact site changed** (0 of 14,598). Receiver exact rate, completion quality and latency are unchanged
within noise; nested anonymous-class requests are slightly faster.

## Corpus and identity (Phase 1)

| Item | Recorded (`corpus.json`) | Measured here |
|---|---|---|
| JDK | Corretto 27.0.1, `ct.sym` `1d0c1599…` | same file hash |
| gson / jackson-core / commons-collections / jOOL | pinned commits, source hashes | all four commits and source hashes match |
| sxb-agent, Balatro4j, sxb-product | commit, source hash, model hash, classpath fingerprint | all match (Balatro4j's worktree hash with the uncommitted `AnteScorerImpl.java`; sxb-agent 172 jars present, 256 missing) |
| sxb-conciliator | measured `762066fd` (16,436 sites), later `aa1d878c` | on disk: `aa1d878c`, source hash `269cb9ae…`, classpath `d02f755a…` (the recorded "later revision") |
| Sampling | 120 files per project, 150 sites per file | same (`JAVA_AUDIT_FILES=120 JAVA_AUDIT_SITES=150`) |

The classpath fingerprint is the SHA-256 of `basename\0size\0sha256` lines for the present compile-classpath jars,
**in path order** (sorting the lines instead gives a different hash; `corpus.json`'s description says "sorted lines").

**Conciliator drift.** The only drift is sxb-conciliator: the reproduction has 16,360 sites against 16,436. Every other
project's value-receiver count is identical to the 16,436-site report; sxb-conciliator's went 265 → 206 (and one fewer
`this`/`super` site), and that project was 100 % exact on both trees. Reconstructing
`762066fd` would mean checking out a commit in that repository, which this work did not touch. All three engines
below were measured on the same 16,360 sites, and the original and hardened engines reproduce the published totals
**project by project** (87: Balatro4j 15, commons-collections 31, gson 6, jOOL 15, jackson-core 9, sxb-agent 11;
10: commons-collections 9, sxb-agent 1).

**Engines.** Original = `HEAD` (`8aad3f2f`) plus the audit harness; hardened = the staged and unstaged working tree
before this change (a byte copy, Swift fingerprint `4507a446…`); proposed = the working tree after it (`3adee36a…`).
The harness and the javac analysis server were identical in all three runs. The hardened and proposed audits were each
run twice with identical results site for site (the audit is deterministic).

### Baseline report (hardened engine, 16,360 sites)

| | Count |
|---|---:|
| Sampled sites | 16,360 |
| Not compared (`this`, `super`, anonymous `new`: javac prints no location) | 1,486 |
| Comparable value receivers | 11,395 |
| Exact (all sites) | 14,598 (value receivers 97.6 %) |
| Equivalent: type variable vs its bound | 164 |
| Equivalent: capture vs its bound / `getClass()` capture | 40 / 62 |
| Genuine buckets | **10** (wildcard arguments differ 5, different class 4, no receiver type 1) |
| Per project | commons-collections 9, sxb-agent 1, every other project 0 |

## B. The 10 sites

| # | Site | javac | Engine before (hardened) | Engine after | Root cause | Impact | Outcome |
|---|---|---|---|---|---|---|---|
| 1 | `CellExtractor:110 counterCells.keySet()` | `Set<<anonymous CellExtractor>.CounterCell>` | `Set<…CellExtractor.$Anonymous<h>.CounterCell>` | same | audit spelling (qualifier stripping leaves `<anonymous …>`) | none: 24 members, = javac | **representation only**, bucket unchanged |
| 2–5 | `:114 :117 :119 :131 counterCells` | `TreeMap<<anonymous …>.CounterCell, …>` | `TreeMap<…$Anonymous<h>.CounterCell, …>` | same | as #1 | none: 56 members, = javac | **representation only** |
| 6 | `:121 counter` | `<anonymous CellExtractor>.CounterCell` (`CellExtractor$1$CounterCell`, member of `CellExtractor$1`, inside method `from`) | `CellExtractor.$Local3604.CounterCell` | `CellExtractor.$Anonymous<h>.CounterCell` | the local-class binder treated a member class of an anonymous class as local: wrong owner (the top-level type), second identity for one class | members right on this site; members lost where the two identities meet (conditional, lub) | **fixed identity**; bucket unchanged (spelling) |
| 7–8 | `:132 cell` (two probes) | as #6 | `$Local3604.CounterCell` | `$Anonymous<h>.CounterCell` | as #6 | as #6 | **fixed identity**; bucket unchanged |
| 9 | `AbstractLinkedList:1093 array.getClass()` (`array : T[]`) | `Class<capture#1 of ? extends Object[]>` | none | `Class<? extends Object[]>` | `JavaMemberLookup.members(of: .array)` returned `length` and `clone()` only; `getClass` did not exist on arrays | no members after `array.`'s `Object` methods; nothing typed after `getClass()` | **fixed**: "no receiver type" → "same class, javac has a capture variable", 85 members = javac |
| 10 | `AgentCreditServiceImp:93 e` in `catch (JsonProcessingException \| JsonPatchException e)` | `JsonPatchException` (jackson-core not on disk) | `JsonProcessingException`, 0 members | `Throwable`, 17 members | `effectiveCatchType` fell back to the first written alternative when the lub was unknown; that alternative had no stub | `e.` offered nothing | **fixed fallback**; still "different class": javac's type is its recovery (below) |

### Cluster A: the anonymous member class

javac (`Tools/JavaReceiverOracle`, section D) places `CounterCell` exactly: binary name
`CellExtractor$1$CounterCell`, nesting `MEMBER`, owners `CellExtractor$1` ← method `from` ← `CellExtractor`.

**First point of information loss.** The scope tree records a type declared directly in an anonymous body as a
`.localType`: the file's stub builder has no stub for an anonymous body, so it has no qualified name.
`JavaAnonymousClass.bindLocalClasses` then registered it like a local class (`owner.$Local<start>.Name`, owner = real
enclosing type). Independently, `JavaAnonymousClass.stub(for:)` registers the anonymous class
`Top.$Anonymous<hash>` and its member types `Top.$Anonymous<hash>.Name`, built from the same declaration by the same
`buildType`. Resolution consults `localTypes` before enclosing types, so the name written in the body won the `$Local`
identity, while a type reached through the anonymous stub's fields kept the `$Anonymous` one.

**Fix (`JavaAnonymousClass.swift`).** A type whose parent is the `class_body` of an `object_creation_expression` is
bound under `anonymousQualifiedName(of: creation) + "." + name`, the name the anonymous stub uses, and its stubs are
built with that owner. The same rule applies where the binder walks owners and the enclosing-type list, so a class
nested in such a member type, or a caret inside it, does not get the made-up `Top.Cell`. Nothing else changed:
local classes keep `$Local<start>`, the registry is still per request, and synthetic names are still never cached.

What the identity is and is not:

* Within a request, one declaration has one name. That name includes a hash of the creation's text, which holds the
  caret's dummy identifier, so it differs between requests. That is the existing contract (stubs name a parse the
  next keystroke replaces), and the tests compare identities within a request.
* Two anonymous bodies with different text are different types (`Twins$1$Nested` / `Twins$2$Nested` stay distinct,
  with different members). Two **textually identical** bodies share one name; javac has `$1` and `$2`. Their
  members are necessarily identical. Distinguishing them would need position in the name, which the `var`
  re-parse path rules out (`stub(for:)` documents why). It is pinned by
  `testIdenticalAnonymousBodiesShareANameAndKeepTheirMembers`.
* Member types written in the anonymous body resolve where they are written: with `T` shadowed by a local class at
  the caret, `x.t` is still `Outer.T`, as for javac (`testAnonymousMemberTypesResolveWhereTheyAreWritten`).

**Why not rewrite the name to javac's.** `<anonymous CellExtractor>` is javac's display string for a class whose
binary name is `CellExtractor$1`. The engine's synthetic name carries the same ownership. The remaining difference is
the harness's spelling, so the 8 sites stay where the audit puts them.

### Cluster B: multi-catch on an incomplete classpath

**Is the index missing a dependency?** The Gradle model (sxb-agent, model `15ef497a…`) lists
`jackson-core-2.19.2.jar` under `~/.gradle/caches/modules-2/…/2.19.2/50f3b4bd…/`. That file no longer exists. Other
jackson-core versions (2.13 … 2.22) are in the cache, and 256 of the model's 428 jars are gone, which is what Gradle's
cache cleanup does to artifacts no recent build used. The model is stale against the Gradle cache. Umbra indexed
exactly what the model lists, and the audit's javac got the same filtered classpath (`classpathJars.filter(exists)`),
so **classpath discovery does not differ between Umbra and javac, and inference is not the cause**. The real fix is
a Gradle re-sync, which would download the jar. That changes the pinned corpus, so it was not done (see G for the
product side).

**javac on the four classpath shapes** (`Tools/JavaReceiverOracle`, Jackson core 2.19.4, json-patch 1.13; both
exception hierarchies are the same as in 2.19.2):

| Classpath | javac's type of `e` | javac reports |
|---|---|---|
| both jars | `Exception` (union of both) | nothing |
| jackson-core only | `JsonProcessingException` | `package com.github.fge.jsonpatch does not exist` |
| json-patch only (the audit) | `JsonPatchException` | `package com.fasterxml.jackson.core does not exist` |
| neither | no type (`<nulltype>`) | both packages missing |
| `LibEx \| IOException`, `LibEx`'s superclass missing | `IOException` (alternative becomes `<any>`) | `cannot find symbol` |
| `IOException \| String` (invalid) | `IOException` | `String cannot be converted to Throwable` |

javac turns every alternative it cannot attribute as a `Throwable` into `<any>`, drops it, and lubs the rest. The answer changes with which jar is missing
and comes with a compile error: it is recovery, not a type the program has.

**Fix (`JavaTypeSystem.effectiveCatchType`).** When the lub cannot be proved, i.e. an alternative has no stub, a
supertype is missing, or the meet climbs above `Throwable` (an incomplete hierarchy or invalid code), the parameter
is `java.lang.Throwable`. JLS 14.20 requires every alternative to be a subclass of `Throwable`, so the real lub is
`Throwable` or below it and has all of `Throwable`'s members. No class relationship is invented. Without a `Throwable`
stub in the index (no JDK yet) nothing is provable and the old fallback stands. With every alternative indexed, the
lub is unchanged (`Exception` for this catch).

At the audited site, `Throwable` offers 17 members, exactly the accessible members of javac's recovery type
`JsonPatchException` (a final class adding no public methods), and the same as the complete-classpath answer
`Exception`. The audit bucket stays "different class" because javac's string is its recovery type.

This **changes behavior an existing test pinned**: `testLubOfAMissingClassIsNotObject` now expects `Throwable` for its
two incomplete catches instead of the first written alternative. Every `lub` assertion in it is unchanged, and its
"not `Object`" intent is now asserted explicitly. `testEffectiveCatchTypeFallsBackToFirst` is unchanged and passes,
because its index has no `Throwable`.

### Cluster C: `getClass()`

**Cause.** The engine could not resolve `getClass` on any array: `arrayMembers` was `length` and `clone()`. JLS 10.7:
an array has `length`, a public `clone()` returning the array type, and every member of `Object` except `clone`.
`JavaUnresolvedMemberInspection` already added `Object`'s members to arrays itself, so the library had the rule in one
place and not in the other.

**Typing rule.** JLS 4.3.2: an invocation of `getClass` has type `Class<? extends |T|>`, where `T` is the type searched
for the method: the receiver's static type, or the enclosing class for an unqualified call. javac then captures the
wildcard. The three things the task asked to keep apart, as the tests check them:

| Expression | Before `.getClass()` | `.getClass()` (engine / javac) | Class represented, via `cast(o)` |
|---|---|---|---|
| `text.getClass()` | `String` | `Class<? extends String>` / `Class<capture of ? extends String>` | `String` / `capture of ? extends String` |
| `array.getClass()` (`String[]`) | `String[]` | `Class<? extends String[]>` | |
| `objects.getClass()` | `Object[]` | `Class<? extends Object[]>` | |
| `matrix.getClass()` (`int[][]`) | `int[][]` | `Class<? extends int[][]>` | |
| `list.getClass()` (`List<String>`) | `List<String>` | `Class<? extends List>` (raw: erasure) | |
| `number.getClass()` (`T extends Number`) | `T` | `Class<? extends Number>` (leftmost bound) | |
| `chars.getClass()` (`E extends CharSequence`) | `E` | `Class<? extends CharSequence>` | |
| `tasks.get(0).getClass()` (`List<? extends Runnable>`) | `Runnable` | `Class<? extends Runnable>` | |
| `getClass()` in `Classes<T>` | (none) | `Class<? extends Classes>` | |

**Options weighed.**

| Option | Correctness | Member lookup, substitution, erasure | Identity and caches | Cost | Taken |
|---|---|---|---|---|---|
| A: specialize `getClass`'s return type to `Class<? extends \|T\|>` | the JLS type before capture; the members of the capture are those of its bound, which `readSubstitution` already reads | unchanged paths: `? extends X` was already a supported argument | no new identity; keys are plain types (`Class<? extends X>`), bounded by the 2,048-entry member cache | one check per candidate list of a call named `getClass` | **yes**, plus the array fix |
| B: limited capture variables | exact | every `switch` over `JavaTypeRef`, `substitute`, `erasure`, `lub`, assignability | per-request ids defeat the member cache (`docs/JAVA_GENERIC_TYPE_AUDIT.md` §2) | large | no |
| C: keep `Class<?>` | members of `Class` right, `cast` and `getEnumConstants` lose `T` | none | none | none | no: B was not needed for this, A is cheap |
| D: defer | the array failure is not a capture problem and could not be deferred | | | | no |

No capture conversion was implemented.

## C. Architecture review

| Area | Change |
|---|---|
| Type model (`JavaTypeRef`) | none |
| Symbol ownership | a type declared directly in an anonymous class body is a member of `Top.$Anonymous<hash>`, not `Top.$Local<start>`; local classes unchanged |
| Registries | none added; the per-request `JavaAnonymousClass.registry` now receives the same stub from both paths (same name, same `buildType`) |
| Substitution / erasure | new `JavaExpressionTyper.erasureOfStaticType` for `getClass` only: a type variable's leftmost bound from the context, at most eight levels deep; `JavaTypeSystem.erasure` unchanged |
| Member lookup | arrays add `Object`'s public instance methods except `clone` (through the cached `Object` member set) |
| Multi-catch | `effectiveCatchType` as in B; `lub` unchanged |
| Caches | none changed. Synthetic names stay uncacheable; a `Class<? extends X>` key is an ordinary type key |

Changed engine files (versus the hardened tree): `JavaAnonymousClass.swift`, `JavaExpressionTyper.swift`,
`JavaMemberLookup.swift`, `Model/JavaTypeSystem.swift`; about 100 changed lines excluding comments.

## D. Differential results

### The receiver audit, three engines, one corpus, one oracle

| Metric (16,360 sites, unchanged rules) | Original | Hardened | Proposed |
|---|---:|---:|---:|
| **Genuine mismatches** | **87** | **10** | **9** |
| Exact (all sites) | 14,521 | 14,598 | 14,598 |
| Value-receiver exact | 96.9 % | 97.6 % | 97.6 % |
| Representation: type variable vs bound | 164 | 164 | 164 |
| Representation: equal up to capture | 40 | 40 | 40 |
| Representation: javac has a capture variable (same class) | 62 | 62 | 63 |
| No receiver type | 56 | 1 | 0 |
| Different class | 13 | 4 | 4 |
| Engine reports `Object` | 10 | 0 | 0 |
| Wildcard arguments differ | 7 | 5 | 5 |
| Unresolved name | 1 | 0 | 0 |
| Invalid candidates (quality harness, held-out) | | 0 / 514 | 0 / 514 |

Per project (genuine): original Balatro4j 15, commons-collections 31, gson 6, jOOL 15, jackson-core 9, sxb-agent 11;
hardened commons-collections 9, sxb-agent 1; proposed commons-collections 8, sxb-agent 1.

**Site-by-site, hardened → proposed**: 40 of 16,360 sites changed, all for the better: 38 `getClass()` sites
`Class<?>` → `Class<? extends X>` (same bucket), `array.getClass()` none → `Class<? extends Object[]>`, and the
multi-catch `JsonProcessingException` → `Throwable`. **No site left `exact`; no representation-only site became
genuine.**

### An independent semantic classification (member sets)

The buckets compare how a type is *written*. They cannot tell the 8 spelling-only sites from a wrong type, and they
missed the dual identity entirely. So a second classification was added **next to** the audit, without changing it:
`JAVA_AUDIT_MEMBERS=<path>` makes the harness dump every compared non-exact site (raw engine type, the engine's full
member list, the receiver's UTF-16 range). `Tools/JavaReceiverOracle/classify_members.py` then has javac report, at
that exact range, the members it makes accessible through the receiver (`Elements.getAllMembers` filtered by
`Trees.isAccessible`, static interface methods excluded; the project's classpath, sourcepath and Lombok on the
processor path), and compares the sets.

| Non-exact compared sites | Original (353) | Hardened (276) | Proposed (276) |
|---|---:|---:|---:|
| member-equivalent | 268 | 264 | **266** |
| engine misses members | 73 | 2 (`array.getClass()`, `AgentCreditServiceImp:93`) | **0** |
| engine misses and offers extra | 2 | 0 | 0 |
| differs only in `Object`'s protected `clone`/`finalize` | 10 | 10 | 10 |

All 8 `CellExtractor` sites are member-equivalent in the hardened and proposed engines (not in the original: 0
members at the three local uses). The 10 protected-member sites are the same in all three engines and are a separate
access-check question (section G).

Both metrics are reported. Neither redefines the other.

### Tests written against javac, not against this repository

`Tests/PenumbraTests/JavaIntelligence/JavaReceiverFidelityTests.swift` (11 tests) runs each fixture through the engine
and through `Tools/JavaReceiverOracle/ReceiverMemberOracle.java` and compares binary name, owner chain and member set.
Run against the hardened engine (the same file copied into the snapshot), **5 fail**, each on the defect it targets:
the two identity tests get `$Local154.Item` / `$Local183.Cell`; the conditional over both identities gets `Comparable`
and misses `count`, `idx`; arrays miss `equals`, `getClass`, `hashCode`, `notify`, `toString`, `wait`; `getClass()` is
`Class<?>`, nil on arrays, and `cast(o)` is `Object`. **6 pass on both engines** and guard behavior that was already
right: two anonymous classes with one nested name, anonymous in anonymous and in a local class, the task's
`Outer.create()` example, edits and document switches with one provider, textually identical bodies, and a shadowed
member type. The last three were written to check for overfitting; they do not come from the audit.

Unit tests (`JavaTypeSystemTests`): multi-catch in both orders with one alternative missing, a missing transitive
superclass whose meet climbs to `Serializable`, an invalid `IOException | String`, the complete classpath, and an
index without `Throwable`.

Corpus cases: `GapArrayObjectMembers`, `GapArrayGetClass`, `GapMultiCatchMissingAlternative` (hard checks; the last
two carry an `//! oracle:` note because javac's spelling is its capture or its recovery).

## E. Performance (release, JDK 27, alternating rounds)

Hardened and proposed `PerfHarness` binaries built from the two trees, run alternately on an idle machine: three
rounds for latency, two for allocations; numbers are the median of the per-round medians.

| Measurement | Hardened | Proposed | |
|---|---:|---:|---|
| member access (small file) | 0.126 ms | 0.120 ms | noise |
| member prefix | 0.152 ms | 0.146 ms | noise |
| generic invocation | 0.539 ms | 0.535 ms | noise |
| 5,000-line member access | 7.04 ms | 7.15 ms | noise (p95 7.28 / 7.56) |
| 5,000-line typing (one provider) | 0.487 ms | 0.492 ms | noise |
| all completion budgets (fast 50 ms, final 150 ms, large 100 ms p95) | pass | pass | p95 ≈ 1.5 ms / 7.5 ms |
| allocations, 5,000-line request | 343.3 KB / 695 | 343.5 KB / 695 | |
| allocations, 120,000 lines | 5.07 MB / 916 | 5.07 MB / 916 | |
| scope-tree build, 2,004 lines (5 alternating rounds × 15) | 4.40 ms (4.30–4.81) | 4.55 ms (4.39–4.77) | code unchanged; ranges overlap |

New `PerfHarness java-anonymous synthetic` (`Tools/PerfHarness/Sources/JavaAnonymousProfile.swift`): a fresh provider
per request, so every request parses and binds.

| Site | Small: hardened → proposed | 5,000 lines: hardened → proposed |
|---|---:|---:|
| anonymous member, local use | 0.202 → 0.200 ms | 7.01 → 7.09 ms |
| anonymous member through a field argument | 0.307 → 0.302 ms | 7.26 → 7.19 ms |
| 8 nested anonymous classes, innermost member | 1.514 → 1.235 ms | 8.48 → 8.06 ms |
| 8 nested, outermost field from the innermost body | 1.952 → 1.654 ms | 8.86 → 8.49 ms |
| `names.getClass().` | 0.069 → 0.169 ms | 6.82 → 7.00 ms |
| multi-catch `e.` | 0.154 → 0.157 ms | 6.98 → 7.01 ms |
| 200 edits of the innermost body, one provider (each edit a new `$Anonymous` hash) | 2.36 → 2.06 ms median | resident memory +0.1 MB → +0.0 MB over 190 edits |

The nested cases got faster because a member class of an anonymous class is now built once per request (it used to
be built twice, once as `$Local` and again through the anonymous stub). `getClass()` on an array costs 0.1 ms more
because it now does the work: on the hardened engine every one of those requests returned **no items** (34 empty
results per run, logged). Memory does not grow with edit history: synthetic names never enter the member cache, and
`Class<? extends X>` keys are bounded by its 2,048-entry limit.

No new recursion without a bound (the erasure walk stops at eight type variables), no whole-file pass per keystroke,
no new synchronization.

## F. Regression results

| Suite | Result |
|---|---|
| `JavaReceiverFidelityTests` (new, javac-backed) | 11 / 11 |
| `JavaTypeSystemTests`, `JavaScopeTreeTests`, `JavaVarInference*`, `JavaLocalClassIdentityTests`, `JavaVisibleLocalsTests`, `JavaMemberLookupTests`, `JavaUnresolvedMemberInspectionTests`, `JavaInlayHintProviderTests`, `JavaLambdaInference*`, `JavaExpressionTyper*` | 210 tests, 0 failures |
| Completion corpus, JDK 25 (the ratchet `baseline.json` is bound to) | 592 cases, 581 passing, 11 known gaps, **no ratchet failure**; hardened: 589 / 578 / the same 11 gaps. 3 new passes. `baseline.json` not updated |
| Completion corpus, JDK 27 | 592 / 581 / 11 |
| `JavaLambdaInferenceOracleTests` (javac 25 and 27) | pass |
| Receiver audit | section D |
| Quality harness (`JAVA_QUALITY_SET=all JAVA_QUALITY_STATS=1`, JDK 27) | report **byte-identical** to the hardened engine's (Phase 7) |
| Full root suite (`swift test`, display on) | 5,318 tests, 26 skipped, 6 failures in 2 tests, **both pre-existing** (below) |
| Full Umbra suite (`swift test --package-path Umbra`, display on) | 2,834 tests, 37 skipped, 15 failures in 8 tests, **all pre-existing** (below) |

**Root failures, known and unrelated.** Both fail identically on the hardened engine (the snapshot's own build):
`JavaGoToImplementationTests.testDefinitionOnConcreteOrStaticDeclarationsStaysEmpty` expects no target on a concrete
declaration and gets the declaration itself (`single: Base`, `run`, `help`, `LIMIT`), which is the documented
"a declaration name selects itself" behavior of Go to Definition, newer than the test.
`RecentFilesSwitcherTests.testReturnWithNoRecentMatchContinuesInGoToFile` is the recent-files UI.

**Umbra failures, known and unrelated.** The 8 failing tests were rerun alone on an idle machine, and 7 of them were
also rerun with the Umbra package built against the **hardened** engine (the Umbra sources copied into the hardened
snapshot, so `..` is the hardened root). They fail identically on both, assertion for assertion:
`GhosttyPtyProcessTests` (`testExitCommandFiresOnce`, `testTermSet`: the terminal process),
`LanguageServiceRegistryTests` (`testUmbraRegistryKeepsTheEngineProviderOrder`,
`testUmbraRegistryOptsOutOfTheSameGenericFeaturesAsBefore`: provider order now includes python, markdown, sql),
`IDELanguageModuleTests.testSettingsPagesKeepTheirOrderWithTheJavaPageBetweenProjectAndAgent` (settings page order), and
`IDEHostEditCostTests` (`testTypingWithTheStructureTabHidden`/`Showing`: 7 parses against a bound of 6 and 5 incremental
against 4, the **same counts** on both engines; this test types into a 20,000-line Java file, which is why it was
bisected rather than reasoned about). The eighth, `SwiftModelTests.testRepositorySwiftFilesStayWithinTheSyntaxProblemCeiling`,
names three files this change does not touch (`Tools/PerfHarness/Sources/JavaAllocationProfile.swift`,
`CompletionLatencyProfile.swift`, `Tests/PenumbraTests/JavaIntelligence/Support/ReferenceRepair.swift`).

### Completion quality (Phase 7)

| Held-out, 3,671 scored sites | Reference (doc, older conciliator tree, 3,676 sites) | Hardened | Proposed |
|---|---:|---:|---:|
| Recall@1 | 67.5 % | 67.7 % | 67.7 % |
| Recall@3 | 86.2 % | 86.2 % | 86.2 % |
| Recall@8 | 92.0 % | 92.0 % | 92.0 % |
| MRR | 0.774 | 0.776 | 0.776 |
| Empty | 0.4 % | 0.4 % | 0.4 % |
| Invalid candidates | 0 / 522 | 0 / 514 | 0 / 514 |
| Incorrect insertions | 0 / 3,551 | 0 / 3,546 | 0 / 3,546 |

Development (1,779 sites): 56.0 % / 83.3 % / 94.2 % / 0.708 on both engines. **No quality improvement is claimed:**
the harness samples prefix completions, and none of its sites is an anonymous member class used both ways, an array
`Object` method, `getClass()` or an incomplete multi-catch. The point is that ranking and filtering did not move.

## G. Remaining limitations

**Representation differences (not engine errors):**

* The 8 `CellExtractor` sites: `<anonymous CellExtractor>.CounterCell` against `$Anonymous<hash>.CounterCell`.
* 63 `getClass()` / capture sites and 40 "equal up to capture" sites: javac's capture variable against the engine's
  wildcard or bound, identical members.
* 164 type variables against their bound.

**Incomplete-classpath artifacts:**

* `AgentCreditServiceImp:93`: javac's recovery type on a classpath with 256 of 428 jars missing.
* **Product gap found on the way:** Umbra does not notice when the jars a Gradle model lists have disappeared from the
  Gradle cache (`jarIndexTargets` indexes the list as is; nothing compares it with the disk). On this machine that is
  60 % of sxb-agent's classpath. A check at project open (`classpathJars` that no longer exist → offer a re-sync) would
  fix the dependency side for real users. Not implemented: it is Umbra UI and a sync, outside the receiver engine.

**Genuine semantic gaps, outside the 10, not fixed:**

* **`Object`'s protected `clone()`/`finalize()` are offered through receivers where JLS 6.6.2.1 forbids them**
  (`Object`- and type-variable-typed receivers, `Class<?>`, and interfaces such as `List<…>`, which do not have them at
  all, JLS 9.2). Found by the member-set classification: 9 of the 276 non-exact sites, and certainly more among exact
  sites, which are not dumped. Same in all three engines, and javac's own answer differs once inside an anonymous class
  (`TypeAdapters:1150`). It is an access-check change across all member completion, so it deserves its own measured
  change rather than riding on this one.
* Textually identical anonymous bodies share one synthetic name (members identical; equality between the two is
  stricter in javac).
* Member classes declared in **enum-constant bodies** (also anonymous classes for javac) are outside this change
  (`anonymousCreation` matches `new … { }` only) and were not tested; they never appeared in the corpus.
* `Object::getClass` as a method reference keeps `Class<?>`.
* Capture variables are still not modeled (`getClass().cast(o)` is the bound, not the capture; same members).
* `G1`–`G6` from the generic audit remain tagged `gap:`.

## H. Recommendation

**READY TO INTEGRATE.** Every change is javac-verified, and the tests that pin each one fail without it. No
previously exact receiver moved (0 of 14,598), no site regressed on member sets, completion quality is byte-identical,
latency and allocations are unchanged within noise, and memory does not grow with edits. Every suite failure
reproduces on the hardened engine.

The target of zero genuine mismatches was not reached by the audit's rules, and it should not be. The 9 that remain
are 8 spellings of a correct identity and 1 javac error-recovery result. Reaching zero would mean changing the
normalization or copying javac's recovery.

Three points need a reviewer's explicit agreement before merging:

1. The multi-catch fallback changed from "first written alternative" to `Throwable`. This rewrites two expectations
   the hardening pass had pinned in `testLubOfAMissingClassIsNotObject`. The test is not weakened: it asserts more
   than before.
2. `JavaReceiverTypeAuditHarness` gained the opt-in `JAVA_AUDIT_MEMBERS` dump. Bucket logic and output are unchanged
   without it.
3. `PerfHarness` gained `java-anonymous`.

**Next, separately:**

* The protected `clone`/`finalize` access check (G), with the member-set classifier as its measurement.
* Detecting a Gradle model whose jars have vanished.

## Files

* Engine: `Sources/JavaIntelligence/Semantics/JavaAnonymousClass.swift`, `JavaExpressionTyper.swift`
  (`specializingGetClass`, `erasureOfStaticType`), `JavaMemberLookup.swift` (arrays), `Model/JavaTypeSystem.swift`
  (`effectiveCatchType`); `Sources/JavaIntelligence/Semantics/CLAUDE.md`.
* Oracle: `Tools/JavaReceiverOracle/ReceiverMemberOracle.java` (plain `java File.java`, no build),
  `Tools/JavaReceiverOracle/classify_members.py`.
* Harness (additive): `JAVA_AUDIT_MEMBERS` in `Tests/PenumbraTests/JavaIntelligence/Differential/JavaReceiverTypeAuditHarness.swift`.
* Tests: `JavaReceiverFidelityTests.swift`, `JavaTypeSystemTests.swift`, corpus cases `GapArrayObjectMembers`,
  `GapArrayGetClass`, `GapMultiCatchMissingAlternative`.

## I. Access correction (after the audit)

The historical tables above are unchanged. The protected-member gap in section G is closed in the engine, and the
member oracle no longer treats `Trees.isAccessible` as the compiler.

`Trees.getScope` re-attributes the enclosing `new` and stops inside the anonymous body while `selectSuper` is still
set, so `Trees.isAccessible` reports `clone` and `finalize` on a nested member class that `javac` rejects
(`clone() has protected access in Object`). The oracle now applies JLS 6.6.2.1 itself: same package, static, or
`super` need only an enclosing subclass; an instance member through another expression also needs the qualifier's
type to be that class or a subclass of it. Public array `clone()` is still added on its own. Receiver-type buckets
are not recomputed.
* Performance: `Tools/PerfHarness/Sources/JavaAnonymousProfile.swift` (`java-anonymous`).
* Reproduce:
  * `JAVA_AUDIT=1 JAVA_AUDIT_FILES=120 JAVA_AUDIT_SITES=150 JAVA_AUDIT_MEMBERS=/tmp/m.jsonl swift test --filter JavaReceiverTypeAuditTests`,
    then `python3 -I Tools/JavaReceiverOracle/classify_members.py /tmp/m.jsonl`
  * `swift test --filter JavaReceiverFidelityTests`
  * `swift run -c release PerfHarness java-anonymous synthetic`
