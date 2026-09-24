# Java Completion: From Strong to IntelliJ-Class

## What changed from the first draft

The first draft was written as if Java completion started from nothing. It doesn't. `JavaIntelligence` already has site classification, a stub index over source, JARs and the JDK, generic-substituting member lookup, expression typing through chains and lambdas, expected-type ranking, auto-import, `@Override` stubs, Gradle classpath scoping, and phased (fast, then slow) results. The capability audit puts it at roughly 70–80% of IntelliJ's everyday value.

So this plan:

1. **Starts from the code that exists.** Phase 0 is a 1-day confirmation, not a rewrite. Its output is already sketched below.
2. **Measures before it builds.** A scored golden corpus comes first. Every later phase has to move a number on it.
3. **Names specific gaps, not categories.** "Support generics" becomes "assignability ignores type arguments, so `List<Integer>` ranks as a match for `List<String>`."
4. **Treats latency as a gate on every phase.** In the first draft performance was the last phase.
5. **Removes work that's already done**: Javadoc sources, bytecode stubs, import organizing, source/JAR unification, cancellation.
6. **States constraints and non-goals**: App Store safety, no compiler in the keystroke path, no new heavyweight dependency.

The goal is the same: know what's valid at the caret, rank the useful candidates first, and never block typing.

---

## Status

| Phase | State | Notes |
|---|---|---|
| 0 | Done | §1 confirmed. G1–G13 confirmed, and G14–G21 added from the corpus. |
| 1 | Done | The corpus is 155 cases in `Tests/PenumbraTests/Fixtures/JavaCompletionCorpus`; `JavaCompletionCorpusTests` runs it against the real JDK. `PerfHarness java-completion synthetic` reports §4.5. Baseline: 116/155 passing, contains 79%, top1 79%. Release perf: member access 0.3 ms, class-name sites 90–130 ms p95 (the first-update gate is missed, G21). |
| 2 | Done | Fixed G1 (generic-aware assignability with wildcard containment, `JavaMemberLookup.asSupertype`), G2 (JLS strict/loose/varargs phases plus most-specific, `JavaExpressionTyper.resolveOverloads`, also used by rename/usages), G3 (explicit method type arguments; target typing through call arguments), G5 (switch, unary, update expressions), G6 (inherited nested types; dotted `Map.Entry`), G14 (type-variable bounds, `for (var x : …)`, class-file `$` nested names with shard format v3), G15 (lambda targets: declaration, assignment, cast, return, nested generic call), G16 (implicit interface `public`, enum `values`/`valueOf`/`Enum` superclass, record `Record`), and G17 (ternary, lambda body, `if (` condition). Corpus: 151/169 passing. |
| 3 | Done | Fixed G4 (the receiver comes from the dummy-identifier tree when it's clean, via `JavaExpressionTyper.treeReceiverRange`; the text scanner crosses line breaks and comments), G7 (`JavaKeywordPosition`: `else`/`catch`/`case`/`yield`/`break`/`continue`/`this`/`instanceof` by position), G12 (the second-invocation access rule is documented, with corpus cases for each side), G19 (class-level access, and same-name classes from different packages), G20 (`package a.b.|`, top-level detection by brace depth; control-statement parens aren't cast sites). Corpus: 173/178 passing, all hard checks clean; the 5 left are G11 ranking and G18. |
| 4 | Done | G21: `JavaIndex.classes(inPackage:)` used to decode every stub on the classpath, and now reads a package table. The index also has a decoded-stub cache, a `generation` counter and a generation-scoped member-set cache (G9). G8: the provider reparses incrementally from its previous tree (on a copy). Release, p95: first update 3.7 ms (was 102 ms), class-name sites 3–5 ms (were 90–130 ms), 5k-line file 22 ms (was 119 ms), typing in it 11.7 ms. The debug corpus runs in seconds, not 98 s. |
| 5 | Done | The ranking features are listed in dominance order on `JavaCompletionPriority`. New named features: first-letter case (`CompletionMatcher`/`DefaultRanker`, as IntelliJ does), package affinity, preferred implementation after `new`, assigned-name affinity after `.`. G18: after `new` with no prefix, concrete implementations from nearby packages are offered. 20 ranking cases added. Corpus: 198/198, top1 100% (48), top5 100% (12). **Caveat:** the expectations are self-authored, and the §4.4 IntelliJ comparison (`intellij_top5`) still needs recording by hand in IntelliJ. |
| 6 | Done | G13 postfix completion (`JavaPostfixTemplates`: `if`, `not`, `while`, `nn`, `null`, `for` (singularized, collision-free name), `fori`, `var`, `return`, `sout`), gated by type and statement position, one undo step. "Implement methods" inserts every missing abstract method in a concrete class. Chain completion stays gated (smart mode, second invocation, or nothing else fits), with precision cases. Also fixed: static interface methods (`List.of`) were offered through instances and subtypes. |
| 7 | Done | `CompletionItem.origin` names the type an inherited member comes from, drawn dimmed after the label; type columns show substituted types (`findById → Optional<User>`), checked by `shows:` corpus cases. Documentation preview: `EditorIntelligenceController` asks the hover engine about the document as it would read with the selected item accepted, debounced, off the main thread, never delaying the popup (`completionDocumentation`, `showsCompletionDocumentation`). |

---

## 1. Current architecture (Phase 0 baseline)

```text
keystroke
  → EditorIntelligenceController (typing observer; debounce; cancels the superseded request)
  → CompletionEngine (JavaCompletionProvider is primary for .java; word/snippet only as fallback)
  → JavaCompletionProvider.provideInScope
       1. repairedText: insert dummy identifier `__penumbra__` (+ `;` at end of a statement line)
       2. full tree-sitter parse of the repaired text (cached by exact text only)
       3. JavaSourceStubBuilder → this file's stubs; JavaResolutionContext (package, imports,
          enclosing types, type parameters)
       4. JavaCompletionContextClassifier → JavaCompletionSite
          (memberAccess, methodReference, importPath, packagePath, annotation,
           annotationAttribute, newExpression, typeOnly, caseLabel, classBody, topLevel,
           statement, cast, stringOrComment)
       5. per-site candidate generation:
          - receiver: JavaReceiverScanner (text, backward) → synthetic snippet re-parse
            → JavaExpressionTyper → JavaTypeResolver
          - members: JavaMemberLookup (supertype walk, generic substitution, access checks)
          - expected type: JavaExpectedType + JavaAssignability
          - classes: JavaIndex (prefix search, scoped to the Gradle source set)
          - extras: JavaCompletionSuggestions (chains, collection factories, lambda templates,
            casts, toArray)
       6. priority: JavaCompletionPriority constants (+ expected-type bonus, adjustments)
       7. phased updates: fast (in scope) first, then slow (classpath-wide)
  → DefaultRanker (match tier → priority → preselect → recency → kind → length)
  → CompletionPanelView
```

Symbols come from `JavaIndex` stubs (`JavaClassStub`: source, class file, JDK), the open-buffer overlay (`JavaOverlayService`), and this file's parse. There's no persistent PSI and no compiler in the loop. That's intentional, and it stays that way (see §9).

**Phase 0 deliverable:** check this diagram against the code, then add one trace per site: which function answers it, and which index queries it makes. Keep the result in this file. Timebox: 1 day.

---

## 2. Known gaps (verified in code, ordered by expected impact)

Each gap names the file where it lives and the corpus cases (§4) it should fix.

| # | Gap | Where | Symptom |
|---|---|---|---|
| G1 | **Erased assignability.** `JavaAssignability` compares erased names, so type arguments are ignored. | `Completion/JavaExpectedType.swift` | `List<String> x = |` ranks a `List<Integer>` local as a match. |
| G2 | **Overload choice by arity plus erased argument names**, with unknown arguments counted as agreeing. | `JavaExpressionTyper.chooseOverload` / `bestOverloads` | `foo(x).|` picks the wrong overload's return type, and the chain then types wrong. |
| G3 | **Generic method type variables aren't bound from the assignment target** (a documented simplification). | `JavaExpressionTyper` | `List<User> u = Collections.emptyList(); u.get(0).|` works through the declared type, but `var u = Collections.<User>emptyList()` and nested target-typed calls fall back to `Object`. |
| G4 | **Receiver extraction is a backward text scan.** It's robust for common chains, but multi-line chains, comments inside chains, text blocks and generic calls (`this.<T>foo()`) are at risk. | `JavaReceiverScanner` | No completion, or `nil` typing, on formatted stream pipelines. |
| G5 | **The typer doesn't cover** `switch_expression`, `unary_expression`/`update_expression`, or a lambda / method reference as a value outside a call argument. | `JavaExpressionTyper.rawTyped` | `(switch (k) { … }).|` gets nothing, and so does `var f = (Function<A,B>) a -> …; f.|`. |
| G6 | **Inherited nested types aren't resolved** (a documented simplification). | `JavaTypeResolver.resolveSimpleName` | `class X extends Base { Entry e; e.| }`, where `Entry` is `Base.Entry`, gets nothing. |
| G7 | **Keywords come from static lists and are gated only on prefix.** `else` is offered with no `if` before it, and `case`/`default`/`yield` are offered outside a `switch`. | `JavaCompletionProvider.statementKeywords` | Noise at the top of short-prefix popups. |
| G8 | **Every request parses the whole file** (the cache is keyed on the exact text, and the dummy identifier changes it on every keystroke). | `JavaCompletionProvider.parse` | Latency grows with file size, and it isn't measured (G10). |
| G9 | **No cross-request semantic cache.** Member sets, supertype closures and resolved receiver types are recomputed on every keystroke. `JavaAssignability` caches only per request. | `JavaMemberLookup`, `JavaAssignability` | The same work repeats while the user re-filters one popup. |
| G10 | **Semantic completion isn't in the perf harness**: `note semantic_completion not_measured reason=java_provider_not_in_harness`. | `Tools/PerfHarness/Sources/InteractiveProfile.swift` | The <100 ms budget can't be enforced. |
| G11 | **Ranking is hand-tuned constants** (`local = 4`, `expectedTypeBonus = 5`, …) plus ad-hoc adjustments, and nothing checks that a change improves ordering overall. | `JavaCompletionPriority`, `memberAdjustment`, `classPriority` | Regressions in ordering go unnoticed. |
| G12 | **Access checks are skipped on the second invocation for statement-position members**, and there's no JPMS module-boundary check. | `JavaMemberLookup.members(checkAccess:)` | Probably intended, like IntelliJ's second Ctrl+Space, but undocumented. JPMS is deferred (audit 7.6). |
| G13 | **No postfix completion** (`.if`, `.for`, `.nn`, `.var`, `.return`). | nothing yet | Missing feature. It's cheap once receiver typing is reliable. |

**Found by the corpus in Phase 1** (not visible from reading the code):

| # | Gap | Where | Corpus cases |
|---|---|---|---|
| G14 | **Receivers that don't type:** a type-variable receiver isn't reduced to its bound (`<T extends Animal> … t.`), `var` in an enhanced `for`, a qualified nested type in a declaration or `new` (`Map.Entry<…> e`, `new User.Builder()`), and `iterator().next()` chains. | `JavaExpressionTyper`, `JavaLocalScope` | `GenericBoundedTypeVar`, `GenericMethodTypeVar`, `GenericEnhancedForVar`, `GenericMapForEach`, `GenericMapEntry`, `ChainBuilder` |
| G15 | **Lambda parameters aren't typed from an assignment target** (`Function<User, String> f = u -> u.|`), or from a generic method whose type variable comes from the outer call (`users.sort(Comparator.comparing(u -> u.|))`). | `JavaExpressionTyper.lambdaParameterType` | `LambdaAssignedFunction`, `LambdaAssignedPredicate`, `LambdaComparator`, `ExpectedLambdaReturn` |
| G16 | **Implicit members of source types are missing:** `values()`/`valueOf()` and the `java.lang.Enum` superclass for a source enum, and default methods of a source interface reached through a class. | `JavaMemberLookup`, `JavaSourceStubBuilder` | `MemberEnumConstant`, `MemberEnumValue`, `MemberInterfaceDefault` |
| G17 | **Missing expected-type sources:** a ternary branch, and an empty `if (` / `while (` condition. | `JavaExpectedType` | `ExpectedTernaryBranch`, `ExpectedBooleanCondition` |
| G18 | **`new` with an empty prefix offers only the expected type and one JDK stand-in**, not the expected type's implementations (`List` → `ArrayList`, `LinkedList`, …). | `JavaCompletionProvider.newExpressionUpdates` | `ExpectedNewList`, `ExpectedNewRunnable` |
| G19 | **Class-level access and same-name classes:** package-private classes from other packages are offered, and a second class with an already-offered simple name is dropped instead of offered qualified. | `JavaCompletionProvider.extraClassStubs`, `inScopeClassStubs` | `VisibilityPackageClassHidden`, `ImportClashExisting` |
| G20 | **Classifier:** `package a.b.|` is classified as member access, and a top-level position after the imports as a statement. | `JavaCompletionContextClassifier` | `SitePackage`, `SiteTopLevel` |
| G21 | **Class-name search latency.** A short class-name prefix takes about 90 ms (release) to the *first* update, because the fast phase already scans on-demand imports and `java.lang`. It misses the 50 ms gate. | `JavaCompletionProvider.inScopeClassStubs`, `JavaIndex.classes(matching:)` | perf harness `class_name_*`, `new_expected` |

Ranking misses the corpus found under G11: `ClassProjectFirst` (`UserS` puts the local `users` above `UserService`, ignoring the case of the first character), `ClassStr`, and `ExpectedAssignedNameMatch` (the assigned-name bonus isn't applied after a `.`).

**Already done, so dropped from scope:** auto-import on accept (`JavaImportInserter`), organize and unused imports, the source/JAR/JDK stub abstraction (the draft's "JavaSymbolSource"), Javadoc from source, `src.zip` and `*-sources.jar` (hover), Gradle-scoped classpath, cancellation of superseded requests, lambda parameter typing at call sites, method references, `@Override` stubs, `case` enum constants, and annotation attributes.

---

## 3. Design principles (revised)

- **The classifier is the context model.** Don't add a parallel `CompletionContext` struct. Grow `JavaCompletionSite` and `JavaResolutionContext` where a gap needs it, for example `isStatic`, `enclosingSwitch` and `previousStatementKind` for G7.
- **Heuristics live only in ranking, and only when measured.** The draft said "no heuristics." The code already has useful ones (`jdkImplementations`, `Exception`-suffix boost, assigned-name match), and IntelliJ has hundreds. The rule: resolution must be semantic. A ranking heuristic is allowed if it has a name, a corpus case, and a measured win.
- **Wrong is worse than missing.** The typer returns `nil` rather than guess, and that stays. A missing popup costs one Ctrl+Space. A confidently wrong member list costs trust.
- **Resolution improvements go into shared code.** `JavaExpressionTyper`, `JavaMemberLookup` and `JavaTypeResolver` also serve go-to-definition, hover, rename, inlay hints and semantic tokens, so fixing G1–G6 there improves all of them. Every fix must keep their test suites green.

---

## 4. Measurement first: the golden corpus and scorecard

This comes before any feature work, because every later phase is judged by it.

### 4.1 Corpus format

`Tests/PenumbraTests/Fixtures/JavaCompletionCorpus/cases/` holds small Java files (a test-bundle resource, next to the fixture `project/`). The caret is marked `/*|*/`, and each case states its expectations in `//! key: value` comment lines in the same file. (A YAML sidecar was planned, but one file per case turned out simpler.) The original sketch was:

```yaml
# stream_filter_lambda.yaml
file: StreamFilter.java
invocation: basic          # basic | second | smart
expect:
  site: memberAccess
  receiverType: com.acme.User
  contains: [getName, getAddress]
  excludes: [privateHelper]
  top1: getName             # optional
  top5: [getName, getId]    # optional, unordered within top 5
  imports: []               # imports added on accept of top1
```

Fixture projects: one single-package folder, one multi-module Gradle project (reusing `GradleFixtures`), and a small JAR with and without a `-sources.jar`. The JDK comes from `TestJDK` (skipped when no JDK is installed, like `JavaCompletionProviderRealJDKTests`).

### 4.2 Case coverage (seed around 120 cases, then grow with every bug)

| Area | Examples |
|---|---|
| Sites | every `JavaCompletionSite` case, including broken code (unclosed parens, missing `;`) |
| Members | fields, methods, inherited, interface defaults, statics via an instance, `this.`, `super.`, `Outer.this.` |
| Generics | `list.get(0).`, `map.entrySet().iterator().next().getValue().`, bounded `T extends Base`, wildcards, raw types |
| Chains | 4+ links, multi-line fluent chains with comments (G4) |
| Lambdas / refs | stream pipelines, `Comparator.comparing(User::|)`, nested lambdas, `var` lambda parameters |
| Expected type | declarations, assignments, `return`, arguments with overloads (G2), ternary branches, generic targets (G1, G3) |
| Visibility | private/package/protected across packages and subclasses, nested-class `private` access |
| Scope | shadowing, pattern variables, record components, enum bodies, anonymous classes, static context |
| Project | cross-module, dependency JAR, generated sources, a class outside the source set (must be hidden on first invocation) |
| Keywords | position-valid keywords only (G7) |
| Imports | same simple name in two packages, nested class import, static import, an existing on-demand import |

### 4.3 Scorecard

`swift test --filter JavaCompletionCorpusTests` runs every case and prints:

```text
cases 124 | site 124/124 | receiver 118/121 | contains 115/124 | excludes 124/124
top1 71% | top5 89% | import-correct 100%
latency p50 18 ms | p95 61 ms | max 140 ms  (debug build, informational)
```

- `site`, `receiver`, `excludes` and `import-correct` are **hard assertions**. They fail the test.
- `top1` and `top5` are **ratcheted**: a checked-in baseline file records the current score, and CI fails if a change lowers it. Raising it updates the baseline in the same commit.
- Each failing case prints its actual top 10 with priorities, so a ranking regression can be diagnosed from the log.

### 4.4 IntelliJ reference

For each corpus case, record once (by hand, in IntelliJ with the same project) the top 5 IntelliJ shows, as `intellij_top5` in the sidecar. The scorecard reports agreement with IntelliJ as an informational column. **Intentional differences** get a `divergence:` note in the sidecar instead of silently counting as misses.

### 4.5 Latency in the perf harness (fixes G10)

Add a `JavaCompletionProvider` stage to `InteractiveProfile` (release build), using a synthetic multi-module project with the JDK index loaded:

| Stage | Budget (p95, release) |
|---|---|
| `java_completion_fast` (first `CompletionUpdate`) | 50 ms |
| `java_completion_final` (last update) | 150 ms |
| `java_completion_large_file` (5k-line file, member access) | 100 ms first update |
| keystroke with Java completion attached | unchanged from the current budget, which completion must never move |

These budgets are gates on every phase below, not a phase of their own.

---

## 5. Roadmap

Each phase lists its exit criteria. A phase is done when its corpus cases pass, the ratchet didn't drop, and the latency gates hold.

### Phase 0: Confirm baseline (1 day)
- Validate §1 and §2 against the code, and fix anything this document got wrong.
- **Exit:** this file updated, with gaps confirmed or struck.

### Phase 1: Corpus, scorecard and harness (about 1 week)
- §4.1–4.5. Seed the corpus. Start the ratchet at whatever today's scores are.
- **Exit:** the scorecard runs in `swift test`, the perf harness reports the Java stages, and the baseline is committed. No behavior changes in this phase.

### Phase 2: Resolution correctness (G1, G2, G3, G5, G6)
Order: G1, then G2, then G3, then G6, then G5. That puts first the fixes that change ranking for the most cases.
- **G1:** make `JavaAssignability` generic-aware: parameterized subtyping through the substitution `JavaMemberLookup` already computes, wildcard containment (`? extends`/`? super`), and raw types treated as assignable (unchecked). Keep the erased check as a fast pre-filter.
- **G2:** overload applicability in Java's three phases (strict, then loose with boxing, then varargs), with most-specific selection over resolved (not erased) parameter types. Report ambiguity instead of guessing: `nil` receiver, and signature help shows every candidate.
- **G3:** bind method type variables from the target type when the arguments leave them open. The `fromTarget` path already exists for arguments; extend it to assignment, `return` and argument targets. Support explicit type arguments (`Foo.<T>bar()`).
- **G6:** resolve simple names through inherited nested types, reusing the `JavaMemberLookup` supertype walk. It's memoizable with the G9 cache.
- **G5:** add typer cases for `switch_expression` (the lub of arm types; simplified to "the common erased type, else `Object`"), unary/update expressions, and lambdas/method references in cast or assignment context.
- **Exit:** generics, expected-type and chain cases at 100% `receiver`; top5 up measurably. Go-to-definition, rename, inlay and hover suites still green.

### Phase 3: Robust receivers and context (G4, G7, G12)
- **G4:** prefer the dummy-identifier tree for the receiver when the node at the caret is a clean `field_access` / `method_invocation` whose object child has no `ERROR` ancestor. Fall back to `JavaReceiverScanner` otherwise. Make the scanner skip comments and handle `.<T>` explicit type arguments.
- **G7:** make keywords position-aware: `else` only after an `if` statement ends, `case`/`default`/`yield` only inside `switch`, `break`/`continue` only in loops or switch, `return` only in a method or lambda body, `this`/`super` not in a static context, `permits`/`sealed`/`non-sealed` only in type headers, `instanceof` only after an expression.
- **G12:** document the second-invocation access rule, and add a corpus case for each side of it.
- **Exit:** multi-line chain and keyword cases pass. Keyword noise in the empty-prefix top 10 is 0 on the corpus.

### Phase 4: Performance (G8, G9), under the Phase 1 gates
- **G8:** incremental parse on the completion path. Keep the last tree for the document and apply `ts_tree_edit` for the user edit (`JavaDocumentParseCache` already does this for overlay and inspections). Then insert the dummy identifier as a second small edit on a *copy* of the tree, so the base tree is never polluted.
- **G9:** a completion-scoped semantic cache in `JavaIndex` (or a sibling actor), keyed on `(qualifiedName, typeArguments, mode, accessContextKey)` for member sets, and on `qualifiedName` for supertype closures. **Invalidation:** clear on an index generation counter (add one to `JavaIndex`, since none exists yet) that bumps when a stub shard changes, when the overlay's stubs for that type's file change, or when the classpath scope changes. It must never outlive a generation. Bound it with an LRU (around 2k entries).
- Reuse the previous request's receiver type when the new request has the same `dotOffset` and document prefix (re-filtering while typing after `.`).
- **Exit:** p95 budgets from §4.5 met on the large-file stage, with no scorecard drop.

### Phase 5: Ranking as a pipeline (G11)
- Replace scattered priority arithmetic with an explicit, ordered feature vector per item: `[expectedTypeMatch, siteRelevance, scopeProximity (local, own, inherited, outer, import, classpath), accessibility, notDeprecated, recency, packageAffinity (same module > project > dependency > JDK internal), nameAffinity (assigned-name match)]`. Compare items lexicographically inside `DefaultRanker`'s match tier.
- Keep it deterministic, with no learned weights. Every feature is named and unit-tested.
- Tune only against the scorecard. A PR that changes ranking posts the before/after top1/top5.
- **Exit:** top1 ≥ 75%, top5 ≥ 92% on the corpus (adjust the targets after Phase 1 shows the baseline).

### Phase 6: Smart features
- **G13 postfix completion:** `.if`, `.not`, `.nn`/`.null`, `.for`/`.fori`, `.var`, `.return`, `.cast`, `.try`. Offer each only when the receiver type fits (`.for` on `Iterable`/arrays, `.nn` on reference types). Apply as one `EnterEdit`-style replacement so undo is a single step.
- Offer "implement all abstract methods" as one item in a class body that has missing abstract methods. The override item builder already exists.
- Offer chain completion (the existing `JavaCompletionSuggestions.chains`) on the second smart invocation only. Measure its precision on the corpus before widening it.
- **Exit:** a corpus case for each postfix template, including the negative cases where it must not appear.

### Phase 7: Presentation
- Show the declaring class for inherited members only (IntelliJ's grey right column), and the type-argument-substituted return type (`get(int): User`, not `E`).
- Load Javadoc for the selected item lazily through `JavaHoverProvider`'s path. It must never delay the popup.
- **Exit:** a snapshot test of panel rows for a set of items.

---

## 6. Import behavior (clarified, mostly existing)

`JavaImportInserter` already decides `none` / `addImport` / `qualify`. Add corpus cases, and fix whatever they expose, for:
- a simple-name clash with an existing single-type import, which must qualify rather than add a second import
- a clash with `java.lang` or a same-package type, which must qualify
- a nested class, which imports the outer type or the nested one following the file's existing convention (default: import the nested type)
- an existing on-demand import that covers the class, which adds nothing
- a static member accepted from class-name completion (`Collectors.toList`), which imports the class, not a static import, unless the file already statically imports from it

---

## 7. External libraries (existing, harden only)

JARs are already indexed once into stub shards, and scoped by the Gradle source set. Remaining work:
- a corpus case for a dependency without sources (a bytecode-only stub: signatures come from `Signature` attributes, and parameter names are absent, so show `arg0`… as `p0`, never an empty name)
- a corpus case for generated sources (`SourceRoot.isGenerated`)
- a corpus case for the first invocation hiding classes outside the source set, and the second invocation showing them

---

## 8. Definition of done: "IntelliJ-class"

All of these, measured on the corpus and in the perf harness in a release build:

| Criterion | Target |
|---|---|
| Site classification | 100% of corpus cases |
| Receiver typing where IntelliJ types it | ≥ 97% |
| Excluded (invalid) candidates shown | 0 on the first invocation |
| Top-1 agreement with the expected item | ≥ 75% |
| Top-5 contains the expected item | ≥ 92% |
| Agreement with the IntelliJ top 5 (informational) | ≥ 80%, divergences documented |
| Import correctness on accept | 100% |
| First update, p95 | ≤ 50 ms |
| Final update, p95 | ≤ 150 ms |
| 5k-line file, first update, p95 | ≤ 100 ms |
| Keystroke latency with completion attached | no regression against the current budget |

---

### Results (2026-09-24, JDK 26, release build)

| Criterion | Target | Measured | Met |
|---|---|---|---|
| Site classification | 100% | 100% of `site:` cases (220-case corpus, all passing) | yes |
| Receiver typing | ≥ 97% | 100% of `receiver:` cases | yes |
| Excluded candidates, first invocation | 0 | 0 | yes |
| Top-1 | ≥ 75% | 100% (51 cases) | yes* |
| Top-5 | ≥ 92% | 100% (12 cases) | yes* |
| Agreement with IntelliJ top 5 | ≥ 80% | **not measured** | **no** |
| Import correctness on accept | 100% | 100% | yes |
| First update, p95 | ≤ 50 ms | 3.8 ms | yes |
| Final update, p95 | ≤ 150 ms | 3.8 ms | yes |
| 5k-line file, first update, p95 | ≤ 100 ms | 22–31 ms (typing, incremental: 11.7 ms) | yes |
| Keystroke with completion attached | no regression | typing_with_intelligence 2.7–4.9 ms median, unchanged; popup open 10.6 ms median with the documentation preview vs 12.1 ms without, so the preview adds no measurable cost | yes |

\* The ranking expectations were written for this corpus, so a perfect score can reflect how
the cases were written as much as how good the ranking is. The IntelliJ comparison is what
checks that. **Still open:** record `intellij_top5` for each ranking case by running the same
snippets in IntelliJ (§4.4). This needs a person with IntelliJ and the fixture project; it can't
be derived from this repository. Until then, "IntelliJ-class" holds against the corpus, not
against IntelliJ itself.

Unrelated failures present before this work and still failing: three `JavaInspectionServiceTests`
and `CommandPaletteControllerTests.testFindActionIDsCoversEveryBuiltInTitledAction`.

## 9. Constraints and non-goals

- **App Store safety.** No `javac`, JDT or LSP server in the completion path. Everything stays in-process on tree-sitter plus stubs. (`javac` diagnostics stay a separate, opt-in, debounced service.)
- **No new dependency** for type inference. Full JLS inference (§18) is out of scope. The G3 target binding covers the cases users hit in practice, and the corpus decides whether more is needed.
- **Not in scope:** JPMS module boundaries (audit 7.6), Kotlin, AI-ranked completion, full-line AI suggestions.
- **Don't regress other consumers.** The typer and lookup are shared, so any change must keep navigation, rename, inlay and semantic-token suites green.
