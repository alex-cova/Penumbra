# Inlay hints final verification

## Release status

The implemented slice spans the editor, native Java, LSP, Code Vision, project JDK configuration and Settings. The production release gates in the plan remain open. The phase table records the unimplemented work and the evidence for the features that landed.

## Phase status

| Phase | Status | Implementation and remaining gates |
| --- | --- | --- |
| 0 · Repository and baseline | Verified with limitations | Read the plan and linked specifications. Audited the existing editor, language, index and JDK paths. Ran both baseline suites. Five synthetic sizes ran on a pre-existing Release harness whose exact source provenance was unavailable. |
| 1 · Rendering | Partially verified | Shared same-anchor spacing, caret geometry and chip hit testing across Core Graphics and Metal. Added padding and grapheme-boundary validation for provider anchors. Existing Code Vision supplies above-line layout. General below-line hints, chips at line start, mixed-direction geometry and comprehensive renderer parity remain open. |
| 2 · Provider lifecycle | Partially verified | Reused language routing and immutable editor snapshots. Viewport range calculation avoids typesetting overscan. Requests coalesce, validate the target buffer and generation, and bound accepted results. Java also validates the index generation. Per-provider parallel publication and a shared split-view result cache remain open. |
| 3 · Native Java | Partially verified | Retained semantic parameter, `var` and lambda hints. Added parse memo reuse, bounded syntax traversal, synthetic-name rejection, qualified-name exclusions, compact type labels and opt-in multiline chains. Full overload/varargs/target-typing acceptance, generic substitution and implicit conversion annotations, declaration links, and a hint-specific javac differential matrix remain open. |
| 4 · LSP | Partially verified | Existing language-service routing owns availability. Added UTF-16 response validation, multipart display, tooltip resolution, padding, registration/unregistration handling, refresh and wire cancellation. Text edits require explicit acceptance against the publishing buffer revision. UTF-8/UTF-32 negotiation, part-level navigation and commands, lazy edits, selector glob parity, and end-to-end coverage for every registered server remain open. |
| 5 · Code Vision | Partially verified | Reused native navigation and the above-line renderer. Java shares the parse memo and checks index readiness, avoiding a definitive zero when available readiness says the index is incomplete. The existing per-declaration lookup remains bounded. Batched file resolution, subclass/override categories and LSP Code Lens remain open. |
| 6 · JDK configuration | Partially verified | Added literal project-root `.sdkmanrc`, `.tool-versions` and `.java-version` annotations. Discovery uses Umbra's JDK service. The actions explicitly select an installed full JDK for this project or open the folder picker. Dedicated module configuration, an in-app download/install path, live sibling-buffer conflict resolution and other build-file formats remain open. |
| 7 · Settings and interaction | Partially verified | Added a searchable Editor subpage, preview, global and workspace visibility, provider controls, Java category controls, theme-derived appearance, exclusions, defaults, context actions and palette commands. Fine-grained appearance controls, configurable shortcut bindings, inline VoiceOver actions and hover activation remain open. |
| 8 · Performance | Partially verified | Added warm and cold native compute and controlled layout benchmarks. The workload and results are recorded in the performance baseline. Full multi-module, split-view, open/close, Instruments and time-to-first-hint coverage remains open. |
| 9 · Verification | Partially verified | Ran deterministic tests and live server probes. The manual checklist and unresolved release gates are below. |

## Architecture and review

- The text buffer and editing engine remain the source of UTF-16 offsets. Virtual chips occupy Core Text advance space and use the existing line-fragment draw paths. Code Vision keeps the existing row-top inset and batched overlay. Same-anchor ghost text is immediately after the semantic chip. The caret continues to support the library's existing before/after visual affinity at that document position.
- The controller keeps a per-editor viewport request. It validates buffer identity as well as generation because a newly loaded buffer can reuse the previous numeric generation. It uses the workbench intelligence identity for split editor snapshots. The materialized buffer comes from the existing off-main shared cache.
- The LSP transport extension uses the existing message framing and forwards other methods to LanguageClient. It bounds in-flight inlay requests, removes cancelled continuations, rejects late responses and advertises the implemented tooltip resolve properties. Explicit text edits use the normal undo group and revalidate offsets and grapheme boundaries before applying.
- Version-manager values are bounded literal strings. They never supply a process, URL, or path. Sibling conflict reads skip symlinks and oversized files. The JDK folder action validates the selected installation against the declaration and uses the project selection only. There is no download or archive extraction path to assess.
- Workspace visibility overrides global visibility for that workspace. Provider and category switches still apply. A fresh profile enables Java parameter, variable and lambda hints. Java method chains and Code Vision stay opt-in.

## Server coverage

| Server or provider | Evidence |
| --- | --- |
| Scripted LSP peer | Runs in the root XCTest suite. Exercises the framed transport and server capabilities without an external process. |
| clangd · Apple clangd 21.0.0 | Direct stdio probe advertised `inlayHintProvider: true` with default UTF-16 and returned a type hint and two parameter hints. The probe exercised the server protocol rather than Umbra's UI. |
| Swift · SourceKit-LSP from Xcode 27.2 | Direct stdio probe initialized. The `initialize` result omitted a static inlay capability and the probe did not send an unsupported request. |
| TypeScript/JavaScript, Go, Kotlin, C# and catalog servers | Routed only when enabled by the language definition and supported by its server. No live inlay results established in this run. |
| Python | Existing Pyright definition omits the inlay feature. No compatible Python server was available on PATH for a probe. |
| Rust | `rust-analyzer` was a rustup proxy with no installed binary in the selected toolchain. |
| Java | Native provider owns Java hints. Platform index baseline fixtures exercised installed JDKs 21, 25, 26 and 27. JDK 24 was absent from that fixture's discovered set. |

## Tests and benchmark evidence

The source and commands are documented in [Performance baseline](PERFORMANCE_BASELINE.md) and the skip reasons are recorded in [Test strategy](TEST_STRATEGY.md).

| Run | Exact command | Result |
| --- | --- | --- |
| Baseline root | `caffeinate -u -d -i -s swift test` | 5,727 XCTest cases, 26 skipped, 0 failures. Swift Testing reported 8 passes. |
| Baseline Umbra | `caffeinate -u -d -i -s swift test --package-path Umbra` | 3,585 XCTest cases, 100 skipped, 0 failures. Swift Testing reported 42 passes. |
| First focused root | `caffeinate -u -d -i -s swift test --filter "InlayHint\|CodeVision\|LSPFakeServer\|LSPPublishedDiagnostics\|JDKConfiguration"` | 86 XCTest cases, 1 failure in the existing flattened LSP hint equality assertion. Corrected display-value equality without changing the test. |
| Focused rerun | `caffeinate -u -d -i -s swift test --filter "InlayHint\|CodeVision\|LSPFakeServer\|LSPPublishedDiagnostics\|JavaVersionDeclaration"` | 86 XCTest cases, no skips or failures in that build. |
| Integrated root milestone | `caffeinate -u -d -i -s swift test` | 5,728 XCTest cases, 26 skipped, 0 failures. Swift Testing reported 8 passes. |
| Integrated Umbra milestone | `caffeinate -u -d -i -s swift test --package-path Umbra` | 3,585 XCTest cases, 100 skipped, 3 failures. Two ordering assertions in `IDELanguageModuleTests` and one adjacency assertion in `IDEMarkdownPreviewSettingsTests` caught the extra permanent sidebar item. Inlay Hints now opens as an Editor subpage and the test assertions are unchanged. |

## Files changed

- `Sources/EditorIntelligence/Inlay` and `Languages` define hint metadata, routing and strict position conversion. `Sources/EditorIntelligenceLSP` owns the protocol translation and transport extension.
- `Sources/JavaIntelligence/Inlay`, `Sources/JavaIntelligence/Discovery/JavaVersionDeclaration.swift` and `Sources/LanguageSyntax/SyntaxTree.swift` implement Java hints, readiness and version-manager parsing.
- `Sources/Penumbra/EditorIntelligenceAdapter`, `TextView/Core`, `TextView/Inlay`, `TextView/LineController`, `TextView/Metal`, `TextView/Gutter` and `Workbench/PenumbraWorkbenchEditorAdapter.swift` cover publication, drawing, interaction and split editor identity.
- `Umbra/Sources/Umbra/Intelligence`, `LanguageServers/IDELanguageServerHost.swift`, `Settings` and `Workspace/IDEWorkspace.swift` wire the providers and controls into the application.
- Deterministic tests live in `Tests/PenumbraTests`. Harness changes are in `Tools/PerfHarness/Sources`. The inlay documentation lives in this directory. The ignore-rule exception makes the requested implementation plan visible in Git status.

## Manual smoke checklist

- [ ] Open a Java file with literal arguments, an inferred local and an implicit lambda parameter. Confirm labels against compiler diagnostics in modules targeting 21, 24, 25 and 26.
- [ ] Compare Metal and Core Graphics at 1× and 2× with tabs, emoji, combining marks, mixed direction, ligatures, wrapping and collapsed folds.
- [ ] Place a chip and ghost completion at one anchor. Check hit testing, caret affinity, selections, multi-cursor, rectangular selection, clipboard and undo.
- [ ] Open two files in split editors. Scroll both panes, switch tabs during a slow request, then verify that each hint belongs to the displayed revision and workspace.
- [ ] Enable clangd in a trusted C++ project. Check hints, tooltip details, a server refresh and cancellation after a quick edit.
- [ ] Inspect Code Vision during indexing and after publication. Open Find Usages and Implementations from the visible labels.
- [ ] Open `.sdkmanrc` and `.tool-versions` with installed, missing, invalid and conflicting declarations. Choose an existing match and verify the project SDK and refreshed indexing.
- [ ] Search Settings for Inlay Hints and check the preview, an exclusion, override precedence, restore defaults, palette commands, right-click actions and VoiceOver.
- [ ] Track editor memory through repeated open, split, switch and close cycles in Instruments. Compare typing and scrolling with a slow LSP server and a large multi-module Java project.

Git history was left unchanged.
