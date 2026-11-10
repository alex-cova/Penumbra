# Java generic type system audit: capture conversion, inference bounds, and what else is wrong

Status: the scope, symbol-registration, overload-applicability, and `var` inference fixes in sections 3 and 8 are in the engine.
Capture conversion and a bound-set solver were not added. The before and after audits use the same javac oracle, the
same 16,436 sites, and the same comparison rules (JDK 27). Companion documents: `docs/JAVA_COMPLETION_QUALITY.md`,
`docs/JAVA_COMPLETION_BASELINE.md`, `Sources/JavaIntelligence/Semantics/CLAUDE.md`.

## Verdict

1. **Capture conversion and inference-variable bounds are not worth building.** The engine already approximates capture
   locally, per member, by substituting the bound; across 11,454 real receivers that approximation produced **zero
   wrong member lists** (266 differences in how a type is *written*, all with identical members). Bounds, intersection
   types and lubs of heterogeneous types occurred **0 times** as a real receiver. The after audit leaves those
   representation buckets unchanged (164 type-variable, 62 capture-variable, 40 equal-up-to-capture).
2. **The 87 genuine mismatches were scope, one applicability rule, and two `var` initializers.** The scope and
   applicability pass took them to **12** (0.10 % of 11,454 value receivers). Exact value receivers moved from 96.9 %
   to 97.6 %, and the same-erased-class rate from 97.5 % to 98.2 %. The 75 sites that left a genuine bucket are the
   75 sites that joined `exact`. No representation-only site became a mismatch. `var` inference then made the two
   `Optional.get()` locals exact, leaving **10** (0.09 %). The inventory is under "After `var` inference".
3. **What landed** (section 8): varargs parameters, `for`-header scope, C-style array declarators, multi-catch lub,
   local and anonymous classes through the existing anonymous-class registry, interface constants, and applicability of
   a wildcard whose bound is an inference variable (`T#`). None of these change the type model.
4. Of the generic items, **generic method references** stay weak (6 of 13 hand-written probes, corpus tags `G1`–`G6`).
   They were not part of this change. They remain rare in real receivers.

## 1. Method

**Oracle.** javac, not the repository's reading of the JLS. For a sample of member accesses `expr.name(...)`, the file is
compiled with `name(...)` replaced by a member that does not exist (`expr.zzProbe()`); javac's `cannot find symbol` names the
receiver (`location: variable l of type ArrayList<String>`). The engine is asked for the receiver at the same site of the
*original* file with the caret after the dot, as when typing. The comparison is of **receiver types**, because a wrong
erased receiver is a wrong member list, and a wrong type argument surfaces one dot later, at a site the sample also
contains. Harness: `Tests/PenumbraTests/JavaIntelligence/Differential/JavaReceiverTypeAuditHarness.swift`
(`JAVA_AUDIT=1 swift test --filter JavaReceiverTypeAuditTests`; `JAVA_AUDIT_EXTRA=<dir>` for hand-written probes).

**Samples.** (a) Real: gson 2.11, jackson-core 2.17, commons-collections 4.5, jOOL 0.9.15, and the Gradle models the
harness loads (Balatro4j, sxb-agent, sxb-conciliator, sxb-product); 120 files per project, up to 150 probes per file,
non-overlapping receivers, deterministic: **16,436 probes, 11,454 comparable value receivers**, 297,441 lines of main
source in 1,437 files for the frequency counts. sxb-product is a member of that run and is absent from the
value-receiver table. (b) Synthetic: `Tests/PenumbraTests/Fixtures/JavaGenericAudit/GenericProbes.java`, 134 probes across
every category the task named, javac-compilable as written.

**Corpus identity.** Revisions, source hashes, and classpath fingerprints are
`Tests/PenumbraTests/Fixtures/JavaReceiverAudit/corpus.json`. A later A/B matches that file: pinned tags at the recorded
commits, Gradle projects at the recorded commits and source hashes, and the recorded jar fingerprints (jars that are
missing on disk are part of the identity; sxb-agent has 172 present and 256 absent). JDK 27.0.1 Corretto
(`27.0.1.0+10-amzn`, `lib/ct.sym` pinned in the same file). The 16,436-site audit used sxb-conciliator `762066fd`
(798 main sources). Commit `aa1d878c` (2026-11-10 09:42, 802 main sources) is a later tree: the same 10 mismatch sites,
206 exact value receivers on that project. Balatro4j's measured sources include uncommitted
`perkeo/src/main/java/com/balatro/impl/AnteScorerImpl.java`; the manifest records both the worktree hash and the clean
commit hash.

**What the oracle cannot say** (excluded or reported separately, never counted as engine errors): `this`/`super`/an
anonymous class (javac prints no location: 1,487 sites), intersection types (no location either), and a union-typed
multi-catch parameter (javac prints one alternative, so those sites are judged by member set). javac writes captures as
`capture#1 of ? extends U`; they are normalised to the bound and reported as their own bucket.

**Mistakes the audit made and fixed before reporting** (they would each have produced a false finding): javac's
diagnostic starts at the *receiver*, not the dot; `this.` has no location line; and a `describe` that glued `?super` to
`java.lang.Integer` let the qualifier-stripping regex eat the keyword, which looked like "wildcards are flattened in
declared types" (the engine preserves them). Two engine hypotheses were also overturned by direct probes (section 4).

## 2. The type model (Phase 1)

| Concept | Representation | Consequence |
|---|---|---|
| Type variable | `JavaTypeRef.typeVariable(name:)`: **by name only**; bounds live on `JavaTypeParameter` in stubs, and in `JavaResolutionContext.typeParameterBounds` keyed by name | identity is a string; a callee's `T` and the caller's `T` collide (fixed for inference by renaming apart to `T#`) |
| Substitution | `JavaTypeSystem.substitute(_:using:)`, a `[String: JavaTypeRef]` map; also an identical private copy in `JavaExpressionTyper` | single pass, no re-substitution, no wildcard-aware variance |
| Wildcard | both `JavaTypeRef.wildcard(bound:)` and `JavaTypeArgument.wildcard(_)`; `JavaWildcardBound` = `extends`/`superBound` | duplicated forms; a top-level wildcard type has no members (`members(of:)` returns `[]`) |
| Capture | **none.** `substitutionMap` maps a captured parameter to its bound (`? extends X` to `X`, `?` to the declared bound or `Object`); `readSubstitution` gives `? super X` its upper bound on reads | capture is applied locally, inside each member walk |
| Upper / lower bounds | upper only, from declarations; **no lower bounds anywhere** (`? super X` is a flag `lowerOnly`, not a bound) | `? super` is correct for reads and arguments, wrong for lambda parameters (section 4) |
| Intersection | none; `T extends A & B` is a type variable with a *list* of bounds (members united), a lub with no single minimum is represented by one component | a lub of `Integer` and `Double` is `Number`, losing `Comparable` |
| Parameterized / raw | `classType(qualifiedName:arguments:outer:)`; raw is empty `arguments` | a raw receiver's members keep their declared type variables (`Set<Entry<K,V>>`) instead of erasing (JLS 4.8) |
| Generic invocation | `inferInvocation`: first-wins `[String: JavaTypeRef]` equality bindings, ordered sources (explicit, non-bare target, plain arguments with lub, nested generic calls, lambda results, bare-return target) | no bound sets, no dependency graph, no incorporation |
| Functional interface | `functionalSignature(of:)`: first abstract non-`Object` method, substituted | `? super X` arguments are read as `X` (write semantics) |
| Assignability | `JavaAssignability`, deliberately permissive ("a raw type, an unresolved name, or a type variable on either side is given the benefit of the doubt") | permissive **except in one place** (section 4, G7) |

**Assumptions that adding capture variables would break:** (a) `JavaTypeRef` equality is type identity (`bindings`
first-wins, `distinct.contains`, `Hashable` keys); fresh variables per expression defeat it. (b) The member-set cache is
keyed by `"\(type)"`; per-request capture ids would make every key unique and the cache useless. (c) `substitutionMap`
assumes parameter-to-bound. (d) `erasure(of:)` maps a type variable to `Object` because bounds are not on the reference.
(e) `lub` is computed on erased names. (f) `JavaAssignability` treats any variable as compatible, which a capture would
inherit but should not.

## 3. Real failures (Phase 2)

### Before

Value receivers: **11,454. Exact 96.9 %; same erased class 97.5 %.** Differences that change no member list: 164 type
variable vs its bound (`V` vs `Object`, `T` vs `Enum<T>`), 40 capture vs its bound, 62 `getClass()` returning
`Class<capture of ? extends X>` vs `Class<?>`. **Genuinely wrong: 87 (0.76 %).**

Bucket counts, all 16,436 sites: exact 14,596; not compared 1,487; javac type variable 164; capture variable 62;
no receiver type 56; equal up to capture 40; different class 13; engine reports `Object` 10; wildcard arguments differ 7;
unresolved name 1.

### After the scope and applicability fixes

Same sample, same oracle, same exclusions. Value receivers: **exact 97.6 %; same erased class 98.2 %.** Genuinely wrong:
**12 (0.10 %)**. All-site exact 14,671. The three representation buckets are unchanged. A re-audit after the
missing-stub guard (`/tmp/java-receiver-audit-review.txt`, same 16,436 sites) keeps exact at 14,671. Genuine buckets:
no receiver type 3, different class 4, wildcard arguments differ 5, unresolved name 0, engine reports `Object` 0.
`AgentCreditServiceImp:93` moved from `Object` to different class (`JsonProcessingException` against javac's
`JsonPatchException`). No other site changed bucket. No site that was exact before the hardening left `exact`.

By project (value receivers, exact before → after): sxb-conciliator 100 % → 100 %, jackson-core 98.9 % → 99.2 %,
Balatro4j 98.2 % → 99.7 %, sxb-agent 97.2 % → 98.1 %, gson 96.6 % → 97.0 %, jOOL 95.9 % → 96.2 %,
commons-collections 95.3 % → 97.4 %. Same-class-only did not rise in any project.

By feature, the moves that matter: `lambda-param` exact 91.7 % → 98.1 % (the jOOL `Accumulator` locals); `field-path`
97.9 % → 100 %; `name` 91.0 % → 93.2 % (n 2,146 → 2,118); `local-or-param` 99.5 % → 99.6 % (n 8,129 → 8,157).
`parenthesized`, `array-access`, `long-chain`, and `has-method-ref` are unchanged.

### The 12 after the scope pass

| Left | Sites | What the engine does | Why it stays |
|---|---|---|---|
| Anonymous local class name | 8 | `CounterCell`, members `idx`, `count`, `compareTo` | javac prints `<anonymous CellExtractor>.CounterCell`. The erased simple name and the members agree. Five of the eight are that name inside a type argument (`Set<…>`, `TreeMap<…>`), so the bucket is "wildcard arguments differ" even though both sides name `CounterCell` |
| `var x = opt.get()` | 2 | exact, after the declaration-end fix | `InvoiceInfoServiceImp:118 item`, `AgentEditQueueListener:319 agentItem`. The initializer was stored and `Optional.get` already substituted `T`. Member completion re-inferred it against locals declared later in the same block, so the earlier `Optional` was invisible. See the re-audit below |
| `array.getClass()` | 1 | no receiver type | `AbstractLinkedList:1093`. javac's receiver is `Class<capture#1 of ? extends Object[]>`. Capture conversion was not added |
| Multi-catch with one alternative missing from the index | 1 | first written alternative | `AgentCreditServiceImp:93 e`, `catch (JsonProcessingException \| JsonPatchException e)`. jackson-core is not on disk. `lub` returns nil (a missing stub must not become `Object`) and the catch stays `JsonProcessingException`. javac drops the unresolved alternative and prints `JsonPatchException`. With both jars present, javac and the engine lub to `Exception` |

`gson ReflectionAccessFilterHelper:95 canAccessMethod` was one of the four "no receiver type" sites. It is a local of a
static initializer used inside an anonymous class. The completion query now builds that initializer, not only the
anonymous method, and the site is exact.

### After `var` inference

Same sample, same oracle, same exclusions (`JAVA_AUDIT_FILES=120`, `JAVA_AUDIT_SITES=150`, 16,436 sites,
`/tmp/java-receiver-audit-var.txt`). All-site exact 14,671 → **14,673**. "No receiver type" 3 → **1**
(`AbstractLinkedList:1093` `array.getClass()`, still `Class<capture#1 of ? extends Object[]>`). Different class stays
4, wildcard arguments differ stays 5, and the three representation buckets are unchanged. No site that was exact left
`exact`. Genuinely wrong: **10 (0.09 %)**.

`InvoiceInfoServiceImp:118 item` and `AgentEditQueueListener:319 agentItem` are exact. Both are `var` initialized from
an earlier `Optional<T>` (`itemOptional.get()`, `agentItemOpt.get()`; the second `Optional` is assigned in a `try`
before the `var`). The scope tree already kept the initializer text, and `Optional.get` already substituted `T`. The
type was lost when member completion re-typed that initializer against the innermost-first local list with the `var`
itself removed, which also dropped every earlier local in the same block. Inference now sees locals whose
`declarationEnd` is before the variable's name. sxb-agent value-receiver exact 98.1 % → 98.4 %. `local-or-param`
exact 99.6 % → 99.7 % (n stays 8,157).

The before measurement, by project (value receivers, exact): sxb-conciliator 100 %, jackson-core 98.9 %, Balatro4j 98.2 %,
sxb-agent 97.2 %, gson 96.6 %, jOOL 95.9 %, commons-collections 95.3 %.

The 87, by first point of loss. The table is the diagnosis; the "First point of loss" cell says whether that cluster
was fixed. A `~` meant a reduced reproduction confirmed the cluster before the line was read:

| Tag | Cluster | Real sites | Real example (file:line, receiver, javac type, engine) | Candidates today | First point of loss |
|---|---|---|---|---|---|
| A4 | local and anonymous classes: members by simple name, captured locals, lambda parameters typed by a local class | **38** | `Balatro4j VectorFilters:239 SEED_HASH_KEY` (`byte[]`, nil; fields of an anonymous class); `jOOL Agg:122 a` (`Accumulator`, a local class; `Object`) x10 | none, or `Object`'s | fixed via the anonymous-class registry (`$Local<start>.Name`, `outerQualifiedName`). Eight `CellExtractor` sites remain a name-spelling difference (`<anonymous …>.CounterCell` vs `CounterCell`); members agree |
| A1 | varargs parameter is not a local | **17** | `gson TypeToken:399 typeArguments` (`Type[]`, nil); `commons FunctorUtils:81 consumers` (`T[]`, nil) x6; `CartesianProductIterator:97 iterables` (`Iterable<? extends E>[]`, **engine says `List<Iterable<…>>`**: the same-named *field*) | none; or the shadowed field's members (wrong) | fixed: `spread_parameter` is registered as an array parameter |
| A2 | `for`-header variable not visible in the update clause (and the condition, when there is an update) | **10** | `gson LinkedTreeMap:339 node = node.parent`; `jackson TokenFilterContext:277 ctxt`; `AbstractLinkedList:922 node` | none | fixed: one `.forLoop` scope covers the condition, the update, and the body |
| A3 | interface constants (implicitly `static final`), by simple name from the interface, an implementor, a record | **8** | `sxb-agent RfcGenericoMx:8 RFC_GENERICO_EXTRANJERO`; `jackson MinimalPrettyPrinter:45`; `Balatro4j RunImpl:17 mapper` | none | fixed: `constant_declaration` is a field. Sibling interface fields of the same name are omitted |
| A5 | multi-catch parameter typed as its first alternative | **7** | `jackson JsonFactory:1882 e` (javac `Exception`, engine `IOException`) | **invalid**: `catch (DateTimeParseException \| NumberFormatException e)` offers `getParsedString`, `getErrorIndex` | fixed: `typedIdentifier` calls `effectiveCatchType` when `alternativeTypes.count > 1`. `DateTimeException` and `NumberFormatException` lub to `RuntimeException`. `AgentCreditServiceImp:93` keeps the first written alternative, `JsonProcessingException`, because `JsonPatchException` has no stub (section 3) |
| G7 | overload applicability: wildcard-bounded type variables | **2** | `jOOL Agg:657 Seq.seq(m)` (`Seq<Tuple2<T,Long>>`, engine `Seq<Object>`); `Functions:47 Seq.of(predicates)` | wrong overload, wrong return shape | fixed: `contains` accepts a wildcard bound only when the bound or the argument is an inference variable (`T#`). The two real sites left the "wildcard arguments differ" bucket (7 → 5, and the five that remain are `CellExtractor`) |
| A6 | `byte b[]` parameter (C-style dimensions) | 1 | `jackson DataOutputAsStream:27 b` (`byte[]`, engine `byte`) | `byte`'s | fixed: a `dimensions` node wraps the type |
| - | `var x = opt.get()`; `array.getClass()` | 3 | `sxb-agent InvoiceInfoServiceImp:118 item` | `item`'s members | `var` fixed: the initializer is typed against locals whose declaring name has already ended. `array.getClass()` stays open (capture was not added). The fourth untraced site (`canAccessMethod`) was the initializer-capture hole and is exact. `Indices` did not reappear |

**What did not show up in real code:** an intersection-typed receiver (0 of 11,454), a receiver that needed a capture
variable to be right (0), a wrong type from inference-variable bounds (0), a wrong type from a conditional or a lambda
with several returns (0). `has-method-ref` receivers (16) were 93.8 % exact.

### Hand-written probes (134, one statement each, javac-checked)

| Category (task list) | n | exact | benign | wrong | no javac type |
|---|---|---|---|---|---|
| `? extends` / `? super` / nested wildcards | 18 | 13 | 5 | **0** | 0 |
| nested parameterized types | 4 | 4 | 0 | 0 | 0 |
| generic methods, return inference, collectors | 32 | 25 | 0 | 5 (`g15 g23 g24 g26 g28`) | 2 (lub) |
| bounds: multiple, recursive, `Enum<E>` | 12 | 7 | 4 | 0 | 1 |
| generic method references | 13 | 7 | 0 | **6** (`m01 m04 m08 m10 m11 m13`) | 0 |
| conditional and `switch` expressions | 8 | 6 | 0 | 1 (`c05`) | 1 |
| lambdas with several returns | 7 | 6 | 0 | 0 | 1 (`r01`) |
| diamond, `var`, anonymous | 6 | 6 | 0 | 0 | 0 |
| raw types | 4 | 2 | 0 | 2 (`raw02 raw03`) | 0 |
| generic classes (inner, inherited, bounded) | 6 | 1 | 4 | 1 (`i01`) | 0 |
| arrays | 4 | 4 | 0 | 0 | 0 |
| local classes, records, enums | 4 | 0 | 0 | **4** | 0 |
| lambda parameters | 12 | 9 | 3 | 0 | 0 |
| scope forms | 4 | 0 | 0 | **4** | 0 |
| **total** | **134** | **90** | **16** | **23** | 5 |

`b08` is benign (javac prints the erasure of a variable). `p07` is typed "benign" but is the one **invalid-candidate**
probe: `List<? super Integer>.forEach(n -> n.|)` offers `Integer`'s members, javac allows `Object`'s.

Failure detail for the generic ones (source: `GenericProbes.java`; expected vs actual receiver):

* **Generic method references** (`m01 Optional::of`, `m04 Collections::singletonList`, `m08` an own `<T> List<T> listOf`,
  `m10 Arrays::asList`, `m11 Set::of`, `m13 Optional::ofNullable` + `Optional::get`): expected `String`, actual `Object`
  (candidates: `equals`, `toString`, `wait`, `getClass`... instead of `length`, `charAt`...). Cause (read in code):
  `methodReferenceResult` ends in `inferMethodTypeVariables($0, argumentTypes: [])`, i.e. the referenced method's `T`
  never receives the functional interface's parameter type, so it falls back to `Object`.
* **Array and constructor references**: `g23 toArray(String[]::new)[0]` expected `String`, actual `Object`; `g28
  toCollection(TreeSet::new).first()` expected `String`, actual `Object`. The second needs the declared bound of the
  target variable (`C extends Collection<T>`) to supply the constructor reference's type arguments: the **only** case in the
  audit that genuinely needs an inference bound.
* `g26 teeing(counting(), summingInt(i -> i), (c, s) -> c)`: expected `Long`, actual `Object`. `g15`, `g24`: `nil`.
* `c05 (f ? List<? extends Number> : List<Integer>).get(0)`: expected `Number`, actual `Object`. `lubKeepingArguments` turns
  differing arguments into `?`; the JLS result is `List<? extends Number>`.
* `raw02 Map raw; raw.entrySet()`: expected raw `Set`, actual `Set<Entry<K,V>>` (declared variables leak); `raw03`.
* Intersection receivers (`g03 Arrays.asList(1, 2.5)`, `g04`, `c03`, `r01`): the engine answers with one component
  (`Number`, `Serializable`, `Integer`), so `compareTo` is missing and, for `r01`, `Integer`'s statics are offered.
  No such receiver occurred in real code.

## 4. Capture conversion (Phase 3)

**Can Umbra represent a capture variable?** Yes, but not cheaply. Stable identity needs a per-expression id (or equality
by bounds), upper and lower bounds need a field `JavaTypeRef` does not have, and the four assumptions in section 2
break. Concretely a `.capture(id:upper:lower:)` case touches `substitute`, `erasure`, `lub`, `asSupertype`, `bind`,
`JavaAssignability`, `members(of:)` and every `switch` over `JavaTypeRef`, and its ids defeat the member-set cache.

**Is it needed?** The evidence says no:

* Every real divergence involving a capture (`equal up to capture`, `getClass()`, `coll.stream()` as `Stream<capture of ?>`) has
  **identical members**, because the members of a capture variable are those of its upper bound, which is exactly what the
  engine substitutes.
* `? extends T`, nested wildcards, `Class<?>`, `Comparator<? super T>`, `Function<? super T, ? extends R>`: 13 of 18 exact, 5
  benign, **0 wrong**.
* The one real divergence is `? super` **as a lambda parameter** (`G5`): the parameter is the capture itself, so its members
  are `Object`'s, and the engine offers the lower bound's. It is an invalid-candidate defect, never seen in the 11,454 real
  receivers, and fixable locally.

**Local rather than global:** this is what the code already does; the audit supports keeping it. If `G5` is ever fixed,
do it where the lambda parameter type is read (`functionalSignature`/`lambdaParameterType`), by using the read
substitution for a parameter that comes from the receiver's own `? super` argument. Do not substitute a wildcard by its
upper bound where that would make the result invalid: the two places that exist today are `readSubstitution` (correct)
and the write substitution used for lambda parameters (the G5 defect).

**Recommendation: do not add capture variables.** Revisit only if a measured defect needs lower bounds in more than one
place.

## 5. Inference bounds (Phase 4)

Today: equality bindings, first writer wins, in a fixed order; a variable's declared bound is used only as the default for
an unbound one; a bare return variable takes the target last (an upper bound in effect). There is no bound set, no
variable-to-variable dependency, no incorporation.

What the failures need, classified:

| Failure | Needs | Is it a bound problem? |
|---|---|---|
| G1 generic method references, G2a `String[]::new`, G3 `teeing` | a **missing constraint source**: the functional interface's parameter types into the referenced method; an array reference's element type; a deferred nested generic call's result | no |
| G7 `Seq.seq(Map)` | an **applicability bug**, now fixed for inference variables only. `contains` returns true when the resolved wildcard bound or the argument is an inference variable (`name` has suffix `#`, the marker `renamedApart` already uses). A class type variable `T`, an unresolved name, and `List<String>` versus `List<? extends Integer>` stay closed. `resolveOverloads` tests applicability on the renamed-apart copy and returns the original stub, so `infer` does not rename twice. The two real jOOL sites select the applicable overload | no (a policy slip) |
| G2b `toCollection(TreeSet::new)` | `C :> TreeSet<α>`, `C <: Collection<T>` therefore `α = T` | **yes, the only one** |
| G4 conditional of `List<? extends N>` and `List<Integer>` | lub with wildcard arguments (lcta) | partly |
| intersection / multi-return `lub` | a representation for `A & B` | not observed in real code |

A general bounded constraint representation would fix G2b and G4 and nothing else, at the cost of rewriting `infer`. The
design instead adds **one rule** for G2b (a constructor reference that names a generic class raw takes its type arguments
from the target variable's declared parameterized bound) and fixes the constraint sources. No solver.

## 6. Complexity, limits and fallbacks (Phase 5)

Present today: inference depth 8 (`maximumInferenceDepth`), a per-question memo for lambda parameters, lub and
most-specific sets capped at 16, a `seen` set for variable-bound cycles, at most three overloads per lambda query, and
every failure returns "unknown" (`nil` or `Object`), never throws. **Cancellation is checked only at the Java provider's stream
boundary (`JavaCompletionProvider`, 3 places) and in the engine; nothing inside the typer or inference checks `Task.isCancelled`.** Safety rests on bounded work, not
interruption.

Risks and proposed explicit limits:

| Risk | Today | Proposed |
|---|---|---|
| Deeply nested parameterized types | `substitute`/`bind` recurse with no cap | cap type depth at 32; deeper reads as unknown |
| Recursive generics (`Enum<E extends Enum<E>>`) | bounds are names, never unfolded: terminates by construction | keep it so: any bound rule unfolds at most one level |
| Cyclic bounds (`T extends U, U extends T`) | `seen` set in `members(ofVariable:)` only | carry a visited set in any new bound reader |
| Ambiguous overloads | `limit: 3`, then `bestOverloads` | cap candidates at 64 before shape filtering (largest seen: 14) |
| Incomplete source | all paths return unknown; tree-sitter error nodes handled | keep; every new rule must be total |
| Cancellation | outside the typer only | one `Task.isCancelled` check at `inferInvocation` entry and per lambda round, returning the fallback |
| Capture identity (if ever added) | n/a | ids must be deterministic per request, never global counters, or the member cache is poisoned |

## 7. Evidence-ranked design (Phase 6)

Ranked by receivers made right per unit of cost and risk, not by JLS completeness. "Share" is the fraction of the 11,454
real value receivers (a lower bound: receivers only, member access only).

| # | Change | Semantic problem | Real evidence | Type-model change | Correctness risk | Perf risk | Regression tests | Expected benefit |
|---|---|---|---|---|---|---|---|---|
| 1 | **Varargs parameters are locals** (`A1`) | `String... names` is not in scope as a local; a same-named field answers instead | 17 sites, 0.15 % | none: declare the parameter with type `T[]` | very low | none | `GapVarargsParameter`, `GapVarargsShadowsField` | +0.15 pt; also removes wrong (not just missing) lists |
| 2 | **`for`-header variables visible in the update clause** (`A2`) | the init variable's scope does not cover `update` | 10 sites, 0.09 % | none | very low | none | `GapForUpdateVariable`, `GapForConditionWithUpdate` | +0.09 pt |
| 3 | **Local classes through the anonymous-class registry; anonymous-class members by simple name** (`A4`) | local type names do not resolve; anonymous-class fields are not found; a local class constructor reference leaves lambda parameters `Object` | **38 sites, 0.33 %** (largest) | none: register local classes like `$Anonymous…` stubs, which exist | medium (type identity of local types; member caches already skip anonymous types) | low | `GapLocalClassVariable`, `GapLocalClassConstructorReference`, `GapAnonymousClassFieldByName` | +0.33 pt |
| 4 | **Wildcard-bounded inference variables are applicable** (`G7`) | `contains` rejects every `? extends T#`/`? super T#`; overloads degrade to arity scoring | 2 sites (0.02 %), but systemic for overloaded generic APIs with different return shapes (jOOL `Seq`, Guava `Lists.newArrayList`) | none | low-medium: more overloads become applicable, so most-specific selection runs where the fallback ran; needs the whole corpus | none | `GapOverloadedSeqMapFromFinisher`, `GapOverloadedSeqMapFromLocal`, `GapVarargsArrayArgument` + unit tests on `isAssignable` | small by count, large per hit (the whole chain after it) |
| 5 | **Interface constants** (`A3`) | implicit `static final` interface fields are not found by simple name | 8 sites, 0.07 % | none | low | none | `GapInterfaceConstantStatic`, `...Implementor`, `...Record` | +0.07 pt; trace the exact cause first |
| 6 | **Multi-catch uses the lub** (`A5`) | `effectiveCatchType` exists and is never called | 7 sites, 0.06 %, and the only wrong-candidate (invalid) cluster in real code | none | low: `Exception`/`Throwable` members for unrelated alternatives | none | `GapMultiCatchMembers` | removes invalid candidates |
| 7 | **Generic method references get input constraints** (`G1`) | the referenced generic method's variables never see the interface's parameter types | 0 real receivers; 6 of 13 probes; 19 generic static references per 297k lines | none | low-medium | low | `GapMethodRefGenericStatic`, `...SingletonList`, `...OwnGenericMethod`, `...ArraysAsList` | whole-chain recovery when it hits |
| 8 | **Array reference result; `C::new` takes arguments from the target's declared bound** (`G2`) | `String[]::new` and `TreeSet::new` read as `Object` | 0 real receivers; 52 `::new` and 8 `[]::new` per 297k lines | none (one bound read, no solver) | low | none | `GapArrayConstructorReference`, `GapToCollectionConstructorReference` | `toArray(X[]::new)[i].` and `toCollection(...)` chains |
| 9 | `byte b[]` dimensions (`A6`) | | 1 site | none | very low | none | `GapCStyleArrayParameter` | rare |
| 10 | `teeing` merger, conditional lcta, raw erasure, `? super` lambda parameter (`G3 G4 G6 G5`) | | 0 real receivers each | G5: read substitution for the lambda parameter | low | none | `GapTeeingMerger`, `GapConditionalWildcardLub`, `GapRawTypeSubstitution`, `GapSuperBoundLambdaParameter` | defer until evidence appears |

**Not recommended:** capture variables, a bound-set solver, intersection types, a general lub. Each is a rewrite of a part
of the type model for zero observed receivers.

## 8. What was implemented

Items 1, 2, 3, 4, 5, 6 and 9 from the table above. Each is a local change; the type model is the same one section 2 describes.

* **Varargs.** `parameterDeclaration` accepts `spread_parameter` and wraps the element type in an array. The parameter is visible in the method body and shadows a same-named field. `GapVarargsParameter`, `GapVarargsShadowsField`.
* **`for` headers.** One `.forLoop` scope covers the condition, the update, and the body. The variable is not visible after the statement. An enhanced `for` still scopes only the body. `GapForUpdateVariable`, `GapForConditionWithUpdate`.
* **C-style dimensions.** `JavaTypeNodeConverter.applying` wraps one array per `[` on a `dimensions` node, for parameters, locals, and fields. `GapCStyleArrayParameter`.
* **Multi-catch.** `typedIdentifier` resolves every alternative and returns `effectiveCatchType`. `GapMultiCatchMembers` lubs to `RuntimeException` (both alternatives extend it) and does not offer `getParsedString` or `getErrorIndex`. When the erased meet is only `Object` and any alternative has no class stub, `lub` returns nil and the catch keeps the first written alternative. Two indexed classes that share nothing but `Object` still lub to `Object`. javac, on `JsonProcessingException | JsonPatchException` (Jackson 2.21.7 core, json-patch 1.13): both jars present, the parameter is `Exception` (`JsonProcessingException` extends `JacksonException` extends `IOException`; `JsonPatchException` extends `Exception`); only json-patch present, javac types the parameter as `JsonPatchException`; only jackson-core present, as `JsonProcessingException`; neither present, javac has no type. The engine does not copy that recovery. A missing hierarchy is unknown, so the parameter stays the first alternative (`JsonProcessingException` in that catch) instead of `Object`.
* **Local and anonymous classes.** Local classes use the anonymous-class registry. The synthetic name is `owner.$Local<startByte>.SimpleName`, so two declarations of the same simple name in different scopes stay distinct. `makeScopedRequest` binds the locals visible at the caret, outermost first, and rewrites the primary stub's `outerQualifiedName` to the real enclosing type so `private` is visible throughout the top-level type. A static or instance initializer is an executable member, so a local declared there is visible inside an anonymous class in that initializer and nowhere else. `GapLocalClassVariable`, `GapLocalClassConstructorReference`, `GapAnonymousClassFieldByName`.
* **Interface constants.** `constant_declaration` is collected with fields and is implicitly `public static final`. Two sibling interfaces that declare the same field name leave it out; a class field and a subinterface redeclaration hide the superinterface field. `GapInterfaceConstantStatic`, `GapInterfaceConstantImplementor`, `GapInterfaceConstantRecord`.
* **G7.** Applicability sees the renamed-apart signature. `contains` opens a wildcard only for an inference variable. `List<String>` is not assignable to `List<? extends Integer>`, to `List<? extends T>`, or to `List<? extends unresolved Integer>`.

Items 7, 8 and 10 (`G1`–`G6`) are still tagged `gap:` and still fail on purpose. The corpus after removing the tags from the fixed cases: 25 cases, 15 passing, 10 known gaps.

If one generic item is wanted next, it is **item 7**, not capture or bounds.

## 9. Validation strategy (Phase 7)

1. **javac differential at the receiver** (built, re-run after the fixes): `JavaReceiverTypeAuditTests` with
   `JAVA_AUDIT=1 JAVA_AUDIT_FILES=120 JAVA_AUDIT_SITES=150`. Gate: value-receiver exact rate must not fall. It rose,
   96.9 % → 97.6 %, and the representation buckets did not shrink into the genuine ones. JDK 27 both times. Do not
   regenerate `baseline.json` from this JDK: the completion ratchet is bound to JDK 25.
2. **javac differential at the candidate** (to build, and the way to detect *invalid* candidates, not only missing ones): a
   new analysis-server request `receiverMembers` returning, per probe, `Elements.getAllMembers` of the receiver type as
   `Types.asMemberOf`, filtered by accessibility. Then `invalid = engine \ javac`, `missing = javac \ engine`, with coverage
   stated as the share of sites javac could type. This would have flagged A5 and G5 without a hand-written case.
3. **Known-gap corpus** (built): 25 `Gap*` cases. The fixed ones (`A1`–`A6`, `G7`) had their `gap:` tags removed and
   are hard checks. `G1`–`G6` stay tagged. The last corpus run on JDK 27: 15 passing, 10 known gaps.
   `JavaLambdaInferenceOracleTests` verifies expectations against javac 25 and 27.
4. **Synthetic edge cases** (built): `GenericProbes.java` (134 probes).
5. **Metamorphic / mutation tests** (to build): re-host every probe inside a varargs method, a `for` header, an anonymous
   class and a lambda body; the receiver type must equal javac's in each. This is the test that would have found A1-A4, which
   are *context* failures. Also mutate the engine (disable the `contains` benefit of the doubt, drop the `readSubstitution`)
   and require the audit to notice.
6. **Quality harness** (run, ranking weights unchanged): JDK 27, `JAVA_QUALITY_SET=all JAVA_QUALITY_STATS=1`.
   Development, 1,779 sites: Recall@1 56.0 %, Recall@8 94.2 %, MRR 0.708, insertions 0 / 1,766, invalid 0 / 281.
   Held-out, 3,676 sites: Recall@1 67.5 %, Recall@8 92.0 %, MRR 0.774, empty 0.4 %, insertions 0 / 3,551,
   invalid 0 / 522 at 99.3 % validation coverage. Detail: `docs/JAVA_COMPLETION_QUALITY.md`.
7. **Performance** (release, JDK 27, three alternating rounds; allocations two rounds, `--samples 3`).
   Final-update medians, before → after: member access 0.118 → 0.121 ms, method prefix 0.138 → 0.142 ms,
   generic invocation 0.491 → 0.520 ms, 5,000-line member access 6.782 → 6.809 ms. Scope-tree build on 2,004 lines
   4.632 → 4.802 ms. A 5,000-line completion allocates 342.1 KB / 686 allocations before and 343.6 KB / 695 after;
   at 120,000 lines both sides allocate 4.95 MB. The added work does not grow with the file. All three completion
   budgets still pass. A second A/B that includes the missing-stub guard
   (`/tmp/java-review-perf.log`) is in the same band: member access 0.116 → 0.124 ms, method prefix 0.138 → 0.142 ms,
   generic invocation 0.501 → 0.513 ms, large-file member access 6.771 → 6.830 ms, scope-tree build 4.799 → 4.914 ms.
   A 5,000-line completion allocates 342.1 KB / 686 allocations before and 343.6 KB / 695 after; at 120,000 lines
   4.94 MB / 907 and 4.95 MB / 916. The extra allocations stay a small constant.

## 10. Limits of this audit

* Receivers of member access only: bare-identifier, `new`, argument and method-reference-name completion are not measured.
* Four of the seven real projects are libraries; stream-heavy application code is under-represented, which is the reason
  items 7 and 8 stay ranked by their probe failures and their occurrence counts instead of being dismissed.
* Private-project sites are cited by file and line only. The corpus those sites came from is pinned in
  `Tests/PenumbraTests/Fixtures/JavaReceiverAudit/corpus.json`.
* Mechanisms marked `~` or "not traced" are confirmed by minimal reproductions, not by reading the failing line.
* Counts of occurrences (`::`, multi-catch, local classes) are from regular expressions over main sources and are
  approximate.

## 11. Files

* Harness: `Tests/PenumbraTests/JavaIntelligence/Differential/JavaReceiverTypeAuditHarness.swift`.
* Corpus identity: `Tests/PenumbraTests/Fixtures/JavaReceiverAudit/corpus.json`.
* Probes: `Tests/PenumbraTests/Fixtures/JavaGenericAudit/GenericProbes.java` (compiles with plain `javac`).
* Proposed corpus: `Tests/PenumbraTests/Fixtures/JavaCompletionCorpus/cases/Gap*.java` (tags `A1 A2 A3 A4 A5 A6 G1 G2 G3 G4 G5 G6 G7`).
* Oracle test widened to `Gap*`: `JavaLambdaInferenceOracleTests`.
* Reproduce:
  `JAVA_AUDIT=1 JAVA_AUDIT_FILES=120 JAVA_AUDIT_SITES=150 swift test --filter JavaReceiverTypeAuditTests` and
  `JAVA_AUDIT=1 JAVA_AUDIT_EXTRA=Tests/PenumbraTests/Fixtures/JavaGenericAudit swift test --filter JavaReceiverTypeAuditTests`.
