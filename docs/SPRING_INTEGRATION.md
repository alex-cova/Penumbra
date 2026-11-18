# Spring integration: architecture audit, plan and parity matrix

Status document for the IntelliJ-Ultimate-class Spring work. Facts here come from the code as audited on
2026-11-17; update the matrix as features land. A feature is **Verified** only when automated tests exercise
it, not when it compiles or has a UI.

## Phase 0: audit findings

| Area | What exists | Consequence for Spring |
|---|---|---|
| Parser / AST | tree-sitter-java via `LanguageSyntax` (`SyntaxTree`, `SyntaxNode`), shared parses in `JavaParseMemo`, per-file `JavaSourceStubBuilder` stubs | Reuse. No second parser. |
| Symbols / types | `Semantics/` (scope tree, `JavaTypeSystem`, `JavaMemberLookup`, `JavaTypeResolver`), `JavaIndex` actor, `JavaInheritorIndex` | Reuse for navigation and type queries. |
| **Gap: annotations** | `JavaClassStub` records no annotations (only `@Deprecated`); class-file reader skips `RuntimeVisibleAnnotations` | Added `JavaDeclaredAnnotations` (source-only, same parse). Library annotations are covered by `SpringAnnotationRegistry`; reading them from JARs is future work. |
| Build | `Gradle*` / `Maven*` models → `JavaGradleProjectModel` (source sets, jars, runtime classpath, main class) | Detection reads dependency coordinates from it (Phase 1b). |
| Run / debug | `JavaRunConfiguration` (targets, VM options, env, before-launch, instrumentation), `IDERunSessions`, `JavaDebugSession` (JDWP via debug adapter), Gradle `bootRun` already offered | Spring Boot config = a run-configuration kind + form section (Phase 4); no new lifecycle layer. |
| UI | `IDEBottomPanelTab`, sidebars (`IDEGradleSidebarPanel`), `IDELeftSidebar`, gutter via `applyJavaGutter`, `JavaLineMarkerProvider`, settings panes (`IDEPreferencesDomain`) | New Spring sidebar tab + settings pane follow these. |
| Diagrams | `Diagrams/` (`IDEDiagramDocument`, canvas, SVG/PNG export, `JavaClassGraph`) | Bean graph = a new document builder, not a new renderer (Phase 3). |
| HTTP | `Umbra/Sources/Umbra/HTTP` (`.http` parse+send) | Endpoint "generate request" targets it. |
| Agent | `Packages/AgentKit` tools, Umbra `Agent/` | Spring facts exposed as tools reading `SpringModel` (Phase 5+). |
| Spring | nothing | Greenfield. |

## Architecture

```
JavaParseMemo tree ──► JavaDeclaredAnnotations (JavaIntelligence, framework-neutral)
                          │  per file: types, fields, methods, params, annotations+args
                          ▼
              SpringProjectModel (actor, SpringIntelligence)
                          │  signature check: body edits do not invalidate
                          ▼
              SpringModelBuilder → SpringModel (immutable, Sendable)
                 beans · injection points · resolutions · diagnostics · cycles · applications
                          ▼
         (next) editor adapter / gutter · tool window · diagrams · run configs · Actuator · agent tools
```

* `SpringIntelligence` depends only on `JavaIntelligence`; no Penumbra, no UI. Umbra wires it (as it wires Java).
* Static facts carry `SpringCertainty` (`certain` / `conditional(reasons)` / `inactive(reasons)`). Runtime facts will be a
  separate type compared against the model, never merged into it.
* Cache/invalidation: per-file declaration signature (ranges excluded); revision bump → lazy whole-model rebuild over
  already-extracted declarations. Per-bean incremental rebuild only after a benchmark shows the need.

### Deliberate semantic decisions
* **Missing is proven only for project-declared types** with no `@Import`/`@ImportResource` anywhere. Library types
  (e.g. `DataSource`) may be auto-configured → `uncertain`, never an error.
* Candidate order follows `DefaultListableBeanFactory.determineAutowireCandidate`: qualifier → `@Primary` → `@Fallback`
  → parameter/field name. `@Resource` resolves by name first.
* Constructor-only cycles of non-deferred singletons are `proven`; any field/setter edge makes it
  `dependsOnConfiguration` (Boot ≥ 2.6 rejects by default). `@Lazy`, `ObjectProvider`, `Provider`, `Optional` break edges.
* Generics: erasure plus directly declared type arguments; arguments reached through chains of generic supertypes are
  unknown and match (never a false mismatch).
* `@Profile` with unknown active profiles is `conditional`; `(`-grouped expressions never mark a bean inactive.
* Custom `@Conditional` and all `@ConditionalOn*` are `conditional`, never evaluated.

## Feature parity matrix (vs IntelliJ IDEA Ultimate)

Legend: NS not started · P partially implemented · U implemented but unverified · V verified

| # | Feature | Phase | Status | Tests | Known limitations |
|---|---|---|---|---|---|
| 1 | Annotation extraction (values, arrays, class literals, params) | 1 | V | `testAnnotationArgumentsAreExtracted` | source files only |
| 2 | Stereotype + meta/composed annotation beans, default bean names | 1 | V | Stereotypes, ComposedAnnotation | custom annotations in JARs unknown; `@AliasFor` not modelled |
| 3 | `@Bean` factory methods (name, aliases, type) | 1 | V | FactoryMethods | `@Bean` array names beyond first become aliases only |
| 4 | Injection points (ctor/field/method/factory param), `@Autowired/@Inject/@Resource/@Qualifier/@Named` | 1 | V | Constructor*, Ambiguity* | `@Autowired` on setters with multiple args fine; `@Value` not an injection point |
| 5 | Candidate resolution: qualifier, primary, fallback, name, collections, Optional, generics | 1 | V | Ambiguity*, Collections*, Generic* | wildcard bounds ignored |
| 6 | Diagnostics: no candidate, ambiguous, unknown qualifier, duplicate names, cycles; shown in the editor and Problems via `SpringDiagnosticProvider` | 1/1b | V (model, provider) / U (Umbra wiring, not UI-tested) | MissingCandidate*, Cycles, Duplicate, `testIndexerScans…` | no quick fixes yet; the provider re-parses the open buffer per request (no shared parse memo access) |
| 7 | Profiles and conditionals (static) | 1 | V (profiles) / P (conditions) | Profiles*, ConditionalOnBean* | conditions never evaluated by design |
| 8 | Incremental updates | 1 | V (signature) / NS (per-bean) | BodyEdit*, Removing* | whole-model rebuild |
| 9 | Entry-point detection (`@SpringBootApplication`) | 1 | V | ApplicationEntryPoint | `SpringApplication.run` call scan, multi-app/module association NS |
| 10 | Project detection from build model (jar coordinates → features, versions, source/resource roots, per module) | 1b | V | `SpringWorkspaceTests` (detection, non-Spring, multi-module) | Gradle/Maven models only; `SpringApplication.run` source scan and per-app launch association NS |
| 11 | Component-scan boundaries and `@Import` (project classes, incl. unannotated ones), `@ComponentScan`/`scanBasePackages`/`basePackageClasses`; `@ImportResource` and library imports make the context opaque | 3 | V | `SpringCrossModuleTests` | `@Enable*` meta-imports, XML bean definitions, library/auto-configuration beans are not modelled |
| 12a | Go to bean from an injected parameter/field name (single or candidate list) | 2 | V (provider) / U (Umbra wiring) | `testGoToDefinitionOnInjectedNameFindsTheBean`, `testTypeNameIsLeftToJava` | only the declared name triggers it; Find Consumers of a bean NS in the UI (`SpringModel.consumers(of:)` exists, tested indirectly) |
| 12b | Quick fixes: add `@Qualifier` per candidate (ambiguous), replace unknown qualifier | 2 | V (provider) / U (Umbra) | `testAmbiguousInjectionOffersQualifierFixes`, `testUnknownQualifierOffersExistingBeanNames` | single-document edits only: no `@Primary`/create-bean/create-implementation fixes (cross-file) |
| 12c | Completion: bean names/qualifiers in `@Qualifier/@Named/@Resource`, profiles in `@Profile` | 2 | V (provider) / U (Umbra) | `testQualifierAndProfileCompletion`, `testSiteDetection` | not yet: property keys, controller mappings, SpEL; shows only when Java returns nothing in the string |
| 12d | Gutter markers: bean, controller, repository, configuration, application entry point, injection point (extensible descriptors; stacking with a count; menu of real actions; per-kind preferences; accessibility) | 3 | V (model, rendering pixels, accessibility elements, stacking, preferences, real-registry merge) / **not verified in a live window** (click-through, popup menu placement) | `GutterExtensionMarkerTests`, `ProviderCompositionTests`, `SpringExplorerTests.testSpringMarkers*`, `SpringToolWindowTests` | scheduled methods and Spring Data repositories have no marker: nothing in the model recognises them |
| 13a | Tool window: Applications, Beans (search, filters, problems), Bean Inspector, Configuration; sidebar tab only for Spring projects; state persisted | 3 | V (store, data layer, render smoke, commands) / **not verified interactively** | `SpringToolWindowTests`, `SpringExplorerTests` | no Data section (no Spring Data analysis); layout judged by pixel-ink only |
| 13b | Endpoints section: list (search, sort by route/method/controller/module, method and module filters, application scope, grouping by controller, inactive/problem filters), inspector, actions | 4 | V (store, data layer, commands, render in both UI schemes, 1,000-endpoint load) / **not verified interactively** (clicks, live key presses, VoiceOver) | `SpringEndpointToolWindowTests`, `SpringEndpointTests` | functional `RouterFunction` routes are not listed (see 15) |
| 13c | Runtime section / Actuator extension point | 3 | Intentionally unsupported for now | — | empty state; no simulated data, no protocol stub that pretends to be a service |
| 14 | Bean dependency graph (constructor/field/method/factory edges; verified/conditional/ambiguous/unresolved; cycles; focus, direction, depth, module/kind filters, external nodes, search, node limit) and application-context graph (imports, scans, factory methods, unknown imports), opened in the existing diagram tabs with export to PNG/SVG/PDF | 3 | V (graph correctness, document building, loading, layout, export, tab reuse) / pan, zoom, fit and search are the existing diagram viewer's | `SpringExplorerTests`, `SpringToolWindowTests` | depth/direction/focus are chosen when opening (tool window and gutter actions), not in the viewer toolbar; status is shown by dash style, label and box colour, not by a distinct edge colour; parent–child contexts are not drawn (unknowable statically) |
| 15a | Annotation-based MVC/WebFlux endpoint index: `@RequestMapping` and the verb shortcuts, class + method composition with `PathPattern.combine` rules, several paths/methods, root and empty mappings, path variables (with regex), wildcards, `${}` placeholders (resolved from configuration where set), composed annotations with `@AliasFor`, interface-declared and inherited mappings, parameter binding, request body type and JSON skeleton, reactive wrappers (`Mono`, `Flux`, `ResponseEntity`…) separated from the payload, `@ExceptionHandler`/`@ControllerAdvice` association, registration status from the controller bean (conditional / inactive under the analysis profile), per-application contexts | 4 | V (against Spring Framework 6.1.11's own `RequestMappingHandlerMapping` for 24 routes with all conditions; discovery, composition, symbols, profiles, modules, WebFlux, incremental invalidation) | `SpringEndpointTests` (41), `SpringRuntimeParityTests` | values the analysis cannot evaluate (a constant in another class, a method call) make the endpoint `partial` and exclude it from conflict checks; `RequestCondition` extensions, `@RequestMapping(version=…)`, `WebMvcConfigurer.configurePathMatch/addPathPrefix` and `server.servlet.context-path` are not applied to the route (the context path is used only for the generated base URL) |
| 15b | Functional routing (`RouterFunctions.route().GET(…)`) | 4 | **NS: documented gap** | — | handler bodies are not part of the declaration model, and reading fluent chains reliably needs expression-level analysis (static imports, nested `nest`, `RouterFunction` beans composed from other beans). Not claimed: the Endpoints list says nothing about functional routes, and its empty state says they are not analysed |
| 15c | Endpoint diagnostics: identical mappings (error), variable-name-only differences (warning), conditional-controller conflicts (warning), malformed patterns, unknown `@PathVariable` (error, with a "bind to {x}" fix), duplicate paths, ignored second mapping annotation (with a "remove" fix), several `@RequestBody`, several binding annotations on one parameter | 4 | V (`SpringRuntimeParityTests` confirms Spring rejects what is reported as an error at startup, accepts what is not reported, and fails the first request for the variable-name case) | `SpringEndpointTests`, `SpringEndpointEngineTests` | conflicts are judged per application context; the `headers = "Accept=…"` ↔ `produces` equivalence is not modelled (a missed conflict, never a false one) |
| 15d | Navigation: route string in a `.http` file or a Java test → handler; `${placeholder}` in a mapping → configuration key; Find Usages on a handler → requests in `.http` files and tests; completion of `@PathVariable("…")` names and `produces`/`consumes` media types | 4 | V (through the real navigation and completion engines) | `SpringEndpointEngineTests` | usages are found by matching the route against request lines and string literals (bounded scan of `.http` files and `src/test`), not by symbol; `WebClient`/`RestTemplate` calls in main sources are not searched |
| 15e | Gutter: one marker per handler method (reveal, copy, generate request, go to controller); the controller's marker lists its endpoints | 4 | V (through the real registry, menu contents) / **not verified in a live window** | `SpringEndpointEngineTests.testHandlersGetAnEndpointMarker…` | |
| 15f | HTTP request generation: method, route with `{{variables}}`, required parameters and headers, `Accept`/`Content-Type` from the mapping, JSON body skeleton from project classes; base URL from `server.port` (+ SSL, context path) or an explicit `<set-the-port>` placeholder; opens an unsaved `.http` buffer and never sends | 4 | V | `SpringEndpointTests`, `SpringEndpointToolWindowTests` | sample values are placeholders (labelled); enum constants and library types are not expanded in the body skeleton |
| 16 | Spring Boot run/debug configuration, lifecycle, logs | 4 | NS | — | build on `JavaRunConfiguration` |
| 17 | Actuator client, static-vs-runtime diff, Keychain credentials | 5 | NS | — | opt-in only; never edit exposure config |
| 18 | Configuration metadata: completion, hover, navigation, placeholders | 2 | V (see Phase 2) | `SpringConfigTests` | |
| 19 | Spring Data repositories and derived queries | 6 | NS | — | |
| 20 | `@Scheduled` + cron; manual trigger | 6 | NS | — | trigger needs opt-in JDI instrumentation; will not ship as a dead button |
| 21 | Spring Security awareness | 6 | NS | — | never claim an endpoint is public |
| 22 | Initializr project creation | 6 | NS | — | extend `ProjectWizard` |
| 23 | Settings category | 2–4 | NS | — | |
| 24 | Agent tools | 5+ | NS | — | no sensitive runtime data without consent |
| 25 | Benchmarks and memory baselines | 7 | NS | — | establish on real projects first |

## Wiring (Phase 1b, done)
`SpringWorkspaceIndexer` (actor) is owned by `IDEJavaSupport.springIndexer`. `refreshSpring()` runs with
`refreshCompilerDiagnostics()` (every model apply): it detects Spring modules from the build model and, only if there are
any, scans their main source roots in the background (size+mtime stamps skip unchanged files; `rescan()` on `.java` file
changes; open buffers via `ingest`). `JavaLanguageService(additionalDiagnostics:)` registers `SpringDiagnosticProvider`.
Non-Spring projects: one pass over jar names, no file reads. Dependent-module sources of a Spring module are not scanned yet.

## Phase 2 wiring
`SpringLanguageService.make(indexer:)` (a `BasicLanguageService` for `java`) carries completion, diagnostics, navigation and
code actions; `IDEIntelligenceServices` registers it *before* Java's service because navigation providers are asked in order
(Java answers an injected name's own declaration with itself, so Spring must be first). Spring's provider is `isPrimary` for Java
documents and returns `nil` unless the caret is on an injection point's name with known candidates. The model skips re-extraction
when a buffer's text hash is unchanged, so repeated requests on one text parse once.

## Next step
1. Gutter markers and a Find Consumers action (see 12d).
2. Configuration-properties assistance (metadata, completion, hover, navigation): `application.properties/yml`.
3. Cross-file quick fixes need a workspace-edit path from code actions (create implementation, `@Primary`, `@Bean`).


## Phase 2 (configuration), Phase 3 (verification) and Phase 4 (architecture): status

### Verified integration findings
Driving Spring through the real `IDEIntelligenceServices` engines (not the providers alone) found defects package
tests could not:
* **Tier routing.** A `BasicLanguageService` is syntactic tier. `LanguageServiceRegistry` asks the highest tier first for
  navigation and lets the highest tier's completion *replace* lower tiers' items, so a syntactic Spring service lost every
  navigation request to Java and had its completion items dropped when Java's answer arrived. Spring's services are now
  semantic-tier structs (`SpringLanguageService`, `SpringConfigLanguageService`); registered before Java's so they are asked first.
* **Fully qualified annotation spelling.** Completion did not recognise `@org.springframework…Qualifier("")`, the form the quick fix writes.
* The registry retags every completion item with the language name, so Spring items are identified by label in tests, not `source`.

### Configuration intelligence (`application*.properties|yml|yaml`)
`SpringConfigParser` (properties, and a bounded YAML subset), `SpringConfigMetadata` (Boot metadata read from the project's own jars
via `ZipArchive`, plus project `@ConfigurationProperties` classes from the semantic model), `SpringConfigModel` (effective values,
diagnostics, imports), providers for completion / hover / diagnostics / navigation / quick fixes.
Semantic decisions:
* **Relaxed binding** compares keys in uniform form (lower case, no `-`/`_`). `SERVER_PORT` is an *environment variable* form and is
  deliberately not equal to `server.port` inside a file.
* **Unknown key** only when the parent path is a known group of the loaded metadata and the key is not under a map, list,
  or unexpanded class property. Keys of libraries without metadata are never judged.
* **Value types** use Spring's binder rules for scalars (`StringToBooleanConverter` words, `Duration`, `DataSize`); enums and
  anything with placeholders or SpEL are accepted.
* **Unresolved placeholder** is a warning that says the value may come from the environment or command line: not provable from files.
* **Precedence** modelled: base < profile files/activated YAML documents (in active order) with `.properties` over `.yml`; environment,
  system properties and command line rank above and are named as unknowable in the hover.
* **Profiles**: analysis selection, else `spring.profiles.active`/`include` from base config; flagged *assumed* when neither exists.
* YAML parser limits: anchors, tags, flow collections and block scalars are opaque values (never flattened or type-checked).
* Limits: no enum value validation (constants are not extracted from source), no `@ConfigurationProperties` on `@Bean` methods,
  no javadoc descriptions for source-derived properties, `.properties` unicode escapes not decoded.

### Phase 4: reusable architecture (Penumbra's gutter is NOT modified)
Built, tested, language-agnostic, and used by Spring:
1. **Composable line markers** — `CompositeLineMarkerProvider` + `LanguageServiceRegistry.lineMarkers(for:)` merge every ready service's
   markers (ordered, de-duplicated by kind/line/anchor, `nil` only if all providers returned `nil`, payloads wrapped so `siblingTargets`
   routes back). A language with one owner gets its provider unchanged.
2. **Workspace-wide code edits** — `CodeAction.workspacePlan: WorkspaceEditPlan?`. The controller sends it to the host's existing
   refactoring preview (`onPresentWorkspaceEditPlan`); it is never applied without that preview. Used by Spring's
   "Make X the @Primary bean" and "Register X as a Spring bean".
3. **Additive Find Usages** — for `.references` the registry merges the answers of all services in the highest tier (framework layers add
   to a language's usages; within one service the first provider still wins; other navigation kinds are unchanged). Spring adds a bean's
   injection points, labelled `Spring injection`.

#### Proposal awaiting review: gutter markers for frameworks (before touching `Sources/Penumbra/TextView/Gutter`)
Today `LineMarkerKind` is a closed Java-specific enum (`implementing`, `overriding`, …) mapped exhaustively in `GutterLineMarker`/
`GutterLineMarkerGlyphs`, `IDEPreferences` (visibility toggles) and `IDEWorkspace`. Composition (above) is only half the problem: a
Spring marker needs a kind. Options:
* **A (recommended): open the kind.** Keep the existing cases, add `case extension(LineMarkerExtensionKind)` where
  `LineMarkerExtensionKind` is `{ id: String, symbol: String (SF Symbol), label: String, group: String }` registered by the service. The
  gutter draws `symbol`; preferences list registered kinds under their `group` ("Spring"). Existing exhaustive switches gain one case.
* B: add `springBean`, `springInjection`, `springEndpoint` cases. Smallest diff, but every future framework repeats it.
Needed before implementation: decision A/B; glyph review (macOS 26 SF Symbols, light/dark, 12 pt); click behaviour (`siblingTargets` reuse
vs. a menu, because a bean's consumers can be many); and a visual-verification plan, since gutter drawing cannot be asserted by the package tests.


## Phase 3 (cross-module analysis, tool window, graphs, extensible gutter)

### Architecture
* **Application contexts** (`SpringApplicationContext`, `SpringProjectModel.contexts()`): one per `@SpringBootApplication` class (found by a light
  annotation pass, not a model build). Scope = the entry module plus its project dependencies (`SpringModuleInfo.dependencyPaths`, from the Gradle
  or Maven model). A class is a bean of the application only inside a scanned package (default: the entry class's package; `scanBasePackages`,
  `@ComponentScan`, `basePackageClasses`) or when imported (`@Import`, even without a stereotype). Scan/import requests found on registered
  configuration classes grow the scope until nothing new appears. Beans are resolved only against that application's own sources, so two
  applications sharing a module never mix. No application class → one `default` context over everything. A file reached by no application
  gets no bean intelligence (`model(for:)` is empty). A file shared by several applications is judged by each: a problem all of them have
  is an error; one only some have is a warning naming them.
* **Detection** now includes plain dependency modules (no Spring jar) so types resolve across the boundary; they are scanned but never diagnosed.
* **Explorer data layer** (`SpringBeanIndex`, `SpringBeanInspection`, `SpringBeanGraph`, `SpringContextGraph`): pure, `Sendable`, built off the main
  actor by `IDESpringStore`, kept until the index revision changes. `SpringModel` carries injection points by owner and consumers by bean.
* **Extensible gutter markers** (Option A): `LineMarkerDescriptor` (namespaced id, SF Symbol, semantic tint, priority, group, accessibility
  label), `LineMarkerMenuItem`/`LineMarkerAction` (navigate / open locations / host command), `LineMarkerKind.extended` (not in `allCases`, so Java
  preferences and saved values are untouched), `LineMarkerPresentation.stacks` (group by line; priority then identity; only exact repeats dropped),
  `LanguageService.lineMarkerDescriptors`, `CompositeLineMarkerProvider`. Penumbra draws `GutterLineMarkerIcon.custom` from a symbol with a
  `GutterLineMarkerTint` (system/theme colours only), draws a count when markers share a line, and exposes one accessibility button per marker.
  Umbra turns a stack into one icon; a click opens a menu of every marker's actions (or performs the only one). Settings list every registered
  descriptor under its group, stored by descriptor id.

### Verification
* Root suite (before this phase's code): 5,477 tests, 21 skipped, 0 failures. See the final report for the post-change runs.
* New tests: `SpringCrossModuleTests` (11), `SpringExplorerTests` (13), `GutterExtensionMarkerTests` (6), `ProviderCompositionTests` (12),
  `SpringToolWindowTests` (17, real indexer + real workspace + real registry + real diagram session/export).
* **Not verified**: anything needing a live window server: mouse clicks on the gutter icon and the pop-up menu, the SwiftUI list's keyboard
  navigation (the list order and selection logic are tested; `.onKeyPress(.return)` is not driven), VoiceOver reading the elements, and visual
  quality (colours/spacing were only checked for non-blank, non-crashing renders).

### Performance (release, `PerfHarness spring synthetic`, 3 modules, real Boot 2.7.6 metadata for the config part)
| | 1,500 beans | 6,000 beans |
|---|---|---|
| index 3 modules (parse + config + metadata) | 140–160 ms | 560–600 ms |
| contexts (scan + import resolution + resolve), before → after fixes | 231 → 79–88 ms | 1,018 → 325–343 ms |
| tool-window snapshot: bean index + bean graph, before → after | 163 → 11 ms | 658 → 51 ms |
| bean search (median / p95) | 1.5 / 2.0 ms | 6.4 / 8.1 ms |
| select bean → inspector, before → after | 2.2 → 0.01 ms | 9.6 → 0.01 ms |
| graph slice (focus depth 2) / capped whole graph | 0.02 / 0.6 ms | 0.03 / 3 ms |
| profile switch or bean-definition edit (context rebuild) | ~80 ms | ~335 ms |
| body edit in a shared module | 0.11 ms | 0.12 ms |
| cost added to an ordinary Java completion (20,000 lines) | 0.03 ms | — |
| memory retained (contexts + index + graph) | ≈ +6 MB | ≈ +47 MB (peak after rebuild loops ≈ +142 MB of allocator garbage) |

Fixes made because the benchmark showed them: URL `path` sorting in every build (twice), a full global model build just to find application
classes, whole-project work for classes outside the scan, per-bean module resolution re-standardising URLs, per-comparison `lowercased()` in the
row sort, per-selection scans of all injection points, and hashing every field of an injection point as a dictionary key.
Known remaining cost: a bean-definition edit or profile switch rebuilds the whole application context (≈ 55 µs/bean); per-bean incremental
rebuild is the next step if that becomes a bottleneck. Not measured: typing latency in a running editor while analysis runs (the analysis is
off the main actor by construction, and the Spring completion provider adds 0.03 ms to a Java completion).

### Remaining IntelliJ parity gaps
(Endpoints were completed in Phase 4 for annotation-based controllers; functional routing remains.) Spring Data repositories and derived queries, `@Scheduled`/cron and its trigger, Spring Security, run/debug configurations and
lifecycle, Actuator runtime inspection and static-vs-runtime diff, Initializr, a Spring settings pane (only gutter-marker toggles exist), agent
tools, `@Enable*` / XML / auto-configuration beans, `@ConfigurationProperties` on `@Bean` methods, enum value validation in configuration,
incremental (per-bean) context rebuild.


## Phase 4 (MVC and WebFlux endpoint intelligence)

### Architecture
- **Extraction** (`SpringEndpointExtractor`, `SpringEndpointModel.swift`). It reuses `SpringModelBuilder`'s name resolution (imports, same package, nested types,
  project annotation types), so an annotation or a type means the same thing as it does for beans: `@GetMapping` is Spring's only when it *resolves* to
  `org.springframework.web.bind.annotation.GetMapping`. Composed annotations are read from their declaration (`JavaAnnotatedType.annotationElements`
  now carries `@AliasFor` and defaults) and merged the way Spring merges them: only attributes declared with `@AliasFor` reach the meta-annotation.
  The class-level mapping and each handler's mapping are found with Spring's search order (the class, its interfaces, its superclass); parameter annotations
  on an interface method bind the implementation's parameters; a route is `SpringRoute.combine` (PathPattern rules), never string concatenation.
- **Index** (`SpringEndpointIndex`): per application context, built from per-controller extractions. Search text is one byte buffer, orders are integer keys, and
  conflicts are grouped on the pattern's structure plus every other condition, so only requests Spring cannot rank are reported.
- **Incremental model** (`SpringProjectModel`). The bean model's signature now ignores Spring web annotations and plain methods
  (`SpringWebAnnotations.webOnly`), so editing a mapping, a parameter binding or a handler's return type rebuilds **no context**. A separate web signature
  and a per-file epoch invalidate exactly the controllers whose own file, or a supertype's, interface's or composed annotation's file changed; a shifted
  handler range re-reads only that controller; a body edit elsewhere reads nothing. Extractions are context-independent, so a profile switch or a module
  change re-decorates (registration status, module, stack, exception handlers) without reading any controller. Everything runs inside the actor, off the main actor.
- **Stack**: MVC when the application's module has `spring-webmvc` (Boot's own choice when both are present), WebFlux when only `spring-webflux`; with no
  build information, reactive handler types decide.
- **Tool window** (`IDESpringEndpointsView`, `IDESpringEndpointInspector`): the snapshot carries each context's `SpringEndpointIndex` and is invalidated by
  `endpointRevision`. Actions: Go to Handler/Mapping, Find Related References, Copy Route, Copy HTTP Method and Route, Generate HTTP Request, Reveal in Application Context.
- **Gutter**: `spring.endpoint` descriptor (priority 43) on handler methods; commands `spring.revealEndpoint`, `spring.copyText`, `spring.generateHTTPRequest`.

### Verification
- `SpringRuntimeParityTests` compiles the controllers against the real Spring 6.1.11 jars (from `~/.m2`), loads them into `RequestMappingHandlerMapping`
  and compares its table with the index: 24 routes with methods, params, headers, consumes and produces (class + method composition, several paths, interface
  and superclass mappings, composed annotations, `/hotels/*` + `/booking`, trailing/leading slashes, `${api.base:/v1}`, any-method vs GET). It also checks the
  conflict rules: identical mappings fail Spring's startup ("Ambiguous mapping") and are errors here; mappings that differ in `produces`, method or specificity
  start fine and are not reported; `/v/{a}` vs `/v/{b}` start fine, fail the first request ("Ambiguous handler methods") and are warnings here. It is skipped when
  `javac` or the jars are absent. Finding while writing it: `@GetMapping` cannot be a meta-annotation (its `@Target` is METHOD), so composed mappings must use `@RequestMapping`.
- Full suites on the final code: root 5,553 tests, 20 skipped, 0 failures (baseline before Phase 4: 5,511); Umbra 3,198 tests, 56 skipped, 0 failures (baseline 3,179). The one added skip is the accessibility-tree test, which SwiftUI cannot satisfy without a running assistive client. One pinned test (`testUmbraRegistryKeepsTheEngineProviderOrder`) was updated because the Spring HTTP service now registers `http` right after `yaml`.
- Engine-level tests (`SpringEndpointEngineTests`) drive the window's real diagnostic, navigation, completion, code-action and gutter-marker registries.

### Performance (release, `PerfHarness spring-endpoints synthetic`, ten endpoints per controller, in-memory)
| | 100 | 1,000 | 10,000 | 5,000 in 8 modules |
|---|---|---|---|---|
| read sources (parse + declarations) | 5.6 ms | 22 ms | 209 ms | 105 ms |
| context build (beans) | 2.3 ms | 9.3 ms | 90 ms | 50 ms |
| first endpoint index (every controller read) | 9.8 ms | 61 ms | 612 ms | 307 ms |
| search, median | 0.01 ms | 0.10 ms | 0.95 ms | 0.51 ms |
| route → handler, median | 0.04 ms | 0.28 ms | 2.9 ms | 1.4 ms |
| mapping-annotation / class-mapping edit → refreshed index | 1.8 ms | 7.2 ms | 68 ms | 34 ms |
| method-body edit (nothing moved) | 0.01 ms | 0.01 ms | 0.01 ms | 0.01 ms |
| unrelated service body edit | 0.03 ms | 0.03 ms | 0.03 ms | 0.03 ms |
| profile switch (contexts + index, no controller re-read) | 1.6 ms | 15 ms | 153 ms | 80 ms |
| memory retained by the index | +1.2 MB | +4.8 MB | +38 MB | +19.5 MB |
| generate an HTTP request | < 0.01 ms | | | |

Before/after of what the benchmark found: index assembly at 10,000 endpoints 127 → 60 ms (a location dictionary built even when there were no diagnostics, string
sort keys), search 26 → 0.95 ms (one lower-cased byte buffer and `memmem` instead of a string search per endpoint), route matching 13 → 2.9 ms (literal prefixes
computed once), an edit's refresh 108 → 68 ms (module and advice resolution once per controller, not per endpoint). My own generator first produced 7,000 genuine
"ambiguous mapping" findings from duplicate paths and then mapping edits that never applied (a mis-escaped string): both were fixture bugs, and the first showed the conflict
check doing its job. The cost the editor pays on an ordinary Java completion is unchanged: 0.04 ms (was 0.03 ms) for Spring's completion provider in a 20,000-line file,
which now also tests two more annotation patterns on the caret's line. Tool window: 1,000 endpoints load and render in the Umbra suite (debug build: snapshot
6.9 s including the disk scan, first render 0.75 s, filter 1.4 ms; release numbers are in the table). Memory is ≈ 3.8 KB per endpoint at 10,000: two struct copies per endpoint
(the controller's cached extraction and the index), their strings, parameters and the search buffer; sharing the cache's copy with the index is the next saving.

### Limitations and gaps (Phase 4)
- Functional routing (`RouterFunctions`), `@HttpExchange` clients, Spring Data REST, Actuator and Spring Security's effect on reachability are not indexed.
- Mapping values the analysis cannot evaluate (constants in other classes, method calls) are shown as `⟨expression⟩`, marked partial and excluded from conflict checks.
- Path-matching configuration (`PathMatchConfigurer`, `server.servlet.context-path` in the route, `spring.mvc.pathmatch`) is not applied to the route; trailing-slash matching
  depends on the Spring version (off by default since 6.0) and is not shown.
- A custom composed annotation placed on a handler is not a web-only annotation to the bean signature, so editing *its* arguments rebuilds the context (the mapping itself is still read from cache).
- Not verified in a live window: gutter clicks and menu placement, Return in the Endpoints list (the handler's effect is tested, the key press is not), keyboard focus order,
  VoiceOver (SwiftUI exposes no accessibility tree to a test; the rows carry combined labels in code), and visual quality beyond light/dark brightness checks.
