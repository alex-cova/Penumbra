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

## Resume run, 2026-11-27 (tree at `42e05c45` plus uncommitted work, no commits)

The handoff's "original plan" link is stale. The plan is `IMPLEMENTATION_PLAN.md` in this directory.

Changes verified in this run: native Java reuses Umbra's existing document syntax cache (`DocumentParseCache`) for files over the memo cap, Java Code Vision batches candidate-file resolution, Metal reuses decoration geometry when lines move vertically, and LSP supports selector globs (`LSPDocumentGlob.swift`) and lazy edits on explicit acceptance.

### Test results

| Run | Command | Result |
| --- | --- | --- |
| Focused | `swift test --filter 'InlayHint\|CodeVision\|LSPFakeServer\|LSPPublishedDiagnostics\|JavaVersionDeclaration'` | 185 cases passed. |
| Root, full | `caffeinate -u -d -i -s swift test` | 5,743 XCTest cases, 25 skipped, 1 failure: `JavaResolutionAuditTests.testRapidEditsWhileSourcesChange` (line 436). Passed 3 of 3 in isolation (`--filter 'JavaResolutionAuditTests/testRapidEditsWhileSourcesChange'`). Intermittent under full-suite load; cause not established. The test and `JavaInspectionService` are not in the diff. Swift Testing: 8 passed. |
| Umbra, full | `caffeinate -u -d -i -s swift test --package-path Umbra` | 3,585 XCTest cases, 100 skipped, 1 failure: `IDEHeapObjectExplorerTests.testASecondTabFindsTheIndexAndDeleteForgetsIt` (10 s wait). Whole class passed in isolation (4 tests). Cause not established. Swift Testing: 42 passed. |
| Umbra, TSan | `swift test --package-path Umbra --sanitize=thread --build-path Umbra/.build-tsan --filter 'IDEHostEditCostTests\|IDEStructureRefreshTests'` | 10 cases, 1 failure: `IDEStructureRefreshTests.testAnEditRebuildsTheTreeAfterThePause` ("new member never showed up", 9.9 s). `IDEStructureRefreshTests` alone under TSan passed 6 of 6. No ThreadSanitizer reports in either run. Timing-sensitive under instrumentation. |
| ACP picker | isolated run (`acp.log`) | `testTodaysCursorAntigravityAndCopilotHandshakesFillThePicker` passed. |
| Whitespace | `git diff --check` | Clean. |

The three full-run failures are unexplained, not fixed. Each passed alone, and none of the three touched files is in the diff.

### Performance gates (Release, Metal, quiet machine)

Binaries: `.build/release/PerfHarness` (rebuilt, 343 s build) against `.build/release/PerfHarness-inlay-baseline`.

Native Java, `java-inlay synthetic --lines 120000 --samples 30`:

| Metric | Baseline | Rebuilt | Budget |
| --- | --- | --- | --- |
| Hints | 162 | 162 | |
| Cold | 1.441 s | 1.364 s | |
| Warm p95 | 1,432 ms | 29.2 ms | 20 ms. **Open**, 9 ms over. |
| Parses over 31 requests | 31 | 0 in memo, 1 in document cache (30 hits) | |
| Stub builds | 31 | 1 | |
| Resident delta | 400 MB | 404 MB | |
| Heap delta | 0.19 MB | 398 MB | Retained parse is now held by the document cache. Needs a decision on whether that is acceptable for a 9.25 MB file. |

Enter, `enter-session synthetic --lines N --samples 40`, 2 rounds alternating hint-off and `PENUMBRA_INLAY_HINTS=180`, all 40 logs report `metal=true`. Values are `enter_fresh_middle` p95 in ms, mean of two rounds:

| Lines | Baseline off / on / delta | Rebuilt off / on / delta | Decoration builds per Enter, on (baseline / rebuilt) |
| --- | --- | --- | --- |
| 1k | 2.623 / 3.971 / +1.349 | 2.753 / 2.942 / +0.189 | 20 / 2 |
| 5k | 2.643 / 3.902 / +1.260 | 2.576 / 2.796 / +0.220 | 20 / 2 |
| 20k | 2.707 / 3.694 / +0.987 | 2.691 / 2.980 / +0.289 | 16–20 / 2 |
| 25k | 2.583 / 3.987 / +1.404 | 2.627 / 2.841 / +0.214 | 20 / 2 |
| 120k | 2.710 / 3.762 / +1.052 | 2.676 / 2.952 / +0.276 | 16–20 / 2 |

The 0.5 ms added-p95 budget is met at every size on the rebuilt binary. Only `enter_fresh_middle` was tabulated. The logs also hold the top-of-file metric.

### Work after the first commit (`eb8e2f7b`)

- **Hint-specific javac differential test** (`Tests/PenumbraTests/JavaIntelligence/JavaInlayHintOracleTests.swift`). Eight samples (`var` from a list, size, split, entry set, optional, stream pipeline, and `for (var …)` over an array and a list). javac (JDK 24.0.2, ct.sym) prints each variable's type through a `zzProbe()` call, and the provider's type-hint label must name the same type. A sample whose type is `Object` must produce no hint. Command: `swift test --filter JavaInlayHintOracleTests`. Result: 1 test, 8 samples, 0 failures. Lambda-parameter hints, pattern variables and chain hints are not yet in the matrix.
- **LSP position encoding: decided not to negotiate.** The client sends `general: nil`, so servers must use UTF-16, and about 69 sites in `Sources/EditorIntelligenceLSP` assume UTF-16 columns. Offering UTF-8 or UTF-32 would touch all of them for a server-side speed gain only. UTF-16 stays the contract. Reopen if a server is found that refuses it.
- **Placement is not started.** A hint's room is added to the previous glyph's kerning (`LineController.swift:554`, `InlayHintLayout.swift` `localOffset >= 1`), so a hint at a line's first column and below-line hints need new typesetting room and parity work in both renderers. They remain open.

- **Native warm p95 closed.** A sample of the 120k-line run showed `_platform_memmove` as 1,353 of about 1,600 busy samples. `JavaNavigationSession.dotOffset(before:)` and `JavaExpressionTyper.receiverInfo` each copied the whole 9.25 MB source (`Array(source.utf8)`) once per call, so a viewport of calls cost O(file). Both now use the tree's own `sourceBytes` (`JavaGoToDefinition.swift`). Result: warm p95 **29.2 ms to 8.7 ms** against the 20 ms budget, 162 hints unchanged, document cache 1 parse and 30 hits. Retained heap is still about 398 MB (the cached tree and stubs), RSS delta about 395 MB. Command: `.build/release/PerfHarness java-inlay synthetic --lines 120000 --samples 30`. The change is shared with go-to-definition, so `swift test --filter Java` ran: 2,082 cases, 7 skipped, 0 failures.

- **Line-start placement implemented** (phase 1). Previously a hint at a line's first column was dropped, because a hint's room is added to the previous glyph's kerning. Now it is local offset 0. The line's first `LineFragment` carries a `leadingInset` (the chip's width), which the typesetter adds to that fragment's width, so wrapping and the content width account for it. The paint frame (`LineFragmentPaintSpec.frame`) is the text frame, shifted right by the inset, and the chip is drawn left of it (`LineInlayHint.leadingX` is `-width` at offset 0). Metal uses the frame directly. The Core Graphics view grows left by the inset and the renderer translates by it. `LineController` adds the inset in `caretX` and removes it in `closestIndex`, and a click on the chip lands at the line start (`inlayHintAnchor`). Ghost text at column 0 is unchanged. Tests: `InlayHintTests` (offset-0 local hint, caret shifts, click on the chip, wrapped line), `MetalDecorationTests.testLineStartChipSitsLeftOfTheTextFrameInBothRenderers` (Metal pill x equals the CG view's left edge). Enter benchmark on Metal, 2 rounds: +0.169 ms at 1k lines and +0.127 ms at 20k (budget 0.5 ms), 2 decoration builds, `metal=true` in all runs. The benchmark has no line-start hints, so it measures the cost of the change on lines without one. Full root suite: 5,748 cases, 25 skipped, 0 failures, including the three tests that failed intermittently in the earlier run.
  Still open for placement: below-line placement (no provider emits it; deferred by decision), no extra caret stop at the chip for arrow keys, ghost text at column 0, and a manual Metal-versus-Core-Graphics check at 1x and 2x.

- **Java hint categories, second pass.** The javac differential test (`JavaInlayHintOracleTests`) now has 16 samples and passes against JDK 24.0.2. New: implicit lambda parameters (`forEach`, `map`, two-parameter `Map.forEach`, `Comparator`), `try (var …)` resources, and `var` components of record patterns (`instanceof` and `switch`, with a primitive component). Lambda parameters already agreed with javac. Two categories were missing and are now implemented in `JavaInlayHintProvider`: `try (var lines = Files.lines(path))` (the scope model already typed it, only the collector was missing) and `Box(var items, var count)`, typed from the record's instance fields in declaration order (nested patterns resolve each record on its own). Record-pattern hints cover non-generic records only: a generic record needs the scrutinee's type arguments, so it gets no hint rather than a wrong one. Provider tests cover the nested, generic, unknown-record, written-type and option-off cases. The harness fixture now puts the file's own types in the index overlay, as the app does. Result: `swift test --filter 'Java|Inlay'` passed 2,120 cases, 7 skipped, 0 failures.
  Still not in the javac matrix: method-chain hints, generic-record patterns, parameter-name hints (overload, varargs, target typing), and implicit conversions.

- **Code Vision subclass and override categories.** `JavaCodeVision.Declaration` now carries an `Inheritance` (none, abstract, subclassable, overridable) in place of `isAbstract`. A class that can be extended (not `final`, `abstract`, an enum, a record or an annotation) gets `N subclasses`, and a method that subclasses can override (not `static`, `private`, `final` or a constructor, in a non-final class, or an interface `default` method) gets `N overrides`. Both appear only when the count is above zero, since most classes have none and a label on each would be noise. The existing `no implementations` label on abstract declarations is unchanged. They share the "Implementation Counts" setting rather than adding a new one. Counting uses the existing `JavaNavigationSession.implementationHits`, which also counts anonymous classes and enum constant bodies, and `JavaGoToImplementation.resolve` now accepts the already-parsed tree so a request no longer reparses the file once per declaration. Tests (`JavaCodeVisionProviderTests`, 4 new): subclasses and overrides counted, no label for leaf methods, `final`, `static` and `private` members, a class without subclasses, final classes, enums and records, an overridden interface default method, and the option switching the labels off. Cost, measured in Debug with 40 searches in one request: 44 ms without the new labels, 130 ms with them. The work is bounded by `maxSearches`, cached per declaration and index generation, and off the typing path. A Release timing was not taken, because the test target does not build in Release. `swift test --filter 'Java|CodeVision|Inlay'`: 2,139 cases, 7 skipped, 0 failures.
  A click on `subclasses` or `overrides` runs Go to Implementation at the declaration, like `implementations` (`CodeVisionRefreshController.handleClick`). `CodeVisionControllerTests` checks that these ids are handled by the editor and not forwarded to the host; it does not observe the navigation itself. LSP Code Lens is covered separately below.

- **LSP Code Lens implemented** (phase 4/5). `codeLensProvider` now maps to the `codeVision` feature, so a server's lenses reach the same above-line renderer as the Java ones. New: `LanguageServerClient.requestCodeLenses`, `resolveCodeLens` (only when the server declared `resolveProvider`, and only if it answers for the same range) and `executeCodeLensCommand`, and `LSPReadyCodeVision` (`Sources/EditorIntelligenceLSP/LSPCodeVision.swift`). Lenses are grouped by the line their range starts on, so two lenses on a line become two labels in one lens. A lens that came without its command is resolved when it is shown, at most 16 per request. A label is the first line of the command's title, trimmed to 120 characters, and an empty title makes no label. The client now advertises `textDocument.codeLens`.
  **Clicks.** `CodeVisionProviding` gained `activateCodeVisionEntry(_:atAnchor:in:)` (default: unhandled), which `RoutedCodeVision` forwards to the owning provider, and `CodeVisionRefreshController` sends `lsp:` entries through it (other ids keep their synchronous path). A `...showReferences` command opens the editor's own references at the symbol position the command carries (not at the lens line), and `...showImplementations` or `...gotoImplementation` opens Go to Implementation. Positions from before an edit are not trusted: after an edit it falls back to the lens anchor. Any other command runs on the server only if the server listed it in `executeCommandProvider`, and only when the user clicks. A command only the server's own editor extension defines is never sent, and a `workspace/applyEdit` that a command asks for is not applied.
  **App wiring.** New setting "Language Server Code Lenses" (Inlay Hints settings, `lspCodeLensEnabled`), **off by default** because each lens reserves a row. `.codeVision` was added to the TypeScript server's and the catalog's standard feature lists (a server still has to advertise `codeLensProvider`), and a server that becomes ready with lens support refreshes the open editors. Java keeps its native labels.
  Tests: `LSPFakeServerTests` (4 new, 27 total, 0 failures): lenses become code vision with one anchor per line and an unresolved lens resolved on demand, `showReferences` activation (and the stale-position fallback after an edit), a server-declared command runs on a click and an extension-defined one does not, and a server without `codeLensProvider` makes no request. Umbra: 83 related tests (`LanguageServer|Preferences|InlayHint|CodeVision|LanguageModule`) passed, 1 skipped. Full root suite (`caffeinate -u -d -i -s swift test`): 5,760 cases, 25 skipped, 0 failures. The full Umbra suite was not rerun. Not verified: the new preference has no unit test; the click path from a real lens through `navigate(.references)` was not exercised end to end; no live server was run. In particular I did not check what gopls, rust-analyzer or typescript-language-server return, and their code lenses depend on server settings (gopls ships most off).

### Gates still open

The three unexplained intermittent failures, and every item the phase table lists as open: line-start and below-line placement with renderer parity, LSP Code Lens, non-UTF-16 LSP encodings and part-level actions, trusted JDK download and install, remaining Java hint categories and the hint-specific javac differential matrix, and end-to-end accessibility and performance checks.

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
