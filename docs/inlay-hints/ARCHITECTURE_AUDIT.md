# Architecture audit

Baseline source is `b391f59311efe45ffde4c1372ccfe64ab0037543`. The initial working tree was clean.

| Area | Existing integration and gaps |
| --- | --- |
| Inline layout | `TextInputView` combines semantic and supplementary hints with a separate completion slot. `LayoutManager` updates loaded line controllers. `LineController` makes room with Core Text kerning. Same-offset ghost text overwrites the chip's kern. Line-start chips have no preceding glyph. |
| Rendering and geometry | `LineFragmentRenderer` and `MetalDecorationBuilder` paint shared line-local hint metrics. `LineController`, `CaretRectService`, and `SelectionRectService` handle caret, mouse and selection geometry. Core Text positions after kerned glyphs are resolved via `InlayChipGeometry`. Wrapped fragments use document offsets. Mixed direction, tabs and grapheme boundaries need dedicated verification. |
| Virtualization and folding | `LineManager` owns row positions and folded heights. Layout retains line controllers near the viewport and adjusts the content offset as wrapped rows above it change height. The gutter edit mapping already shifts declaration annotations through line edits. |
| Block layout | `CodeVisionStore` feeds row-top insets to `LineManager`; `CodeVisionController` displays the visible rows in a batched AppKit overlay. Inline completion has a separate single-row bottom inset for multiline suggestions. |
| Providers | `InlayHintController` has one routed provider, a cancellable debounce, overscan in vertical pixels, and content-generation validation. It lacks explicit range and cardinality validation at publication. Independent Code Vision refresh already exists. |
| Java | `JavaNavigationSession`, `JavaExpressionTyper`, and scoped `JavaIndex` resolve calls and inferred locals. Existing hints build their own tree and stubs even though navigation has `JavaParseMemo`. Constructor binding is conservative and Java Code Vision performs capped searches per declaration. |
| LSP | `LanguageServerClient` uses LanguageClient for JSON-RPC and prepares request-time document sync. `LSPLanguageService` and `LanguageServiceRegistry` route supported features. Basic static inlay requests flatten labels, and existing conversions mostly assume UTF-16. |
| SDK and projects | `JDKLocator`, `JDKInstallation`, `JDKSelectionStore`, `IDEJDKSelection` and `IDEJDKMenu` cover discovery and JDK choices. Maven and Gradle own separate project facts and classpaths. Resolve configuration annotations through these components. |
| Settings and navigation | Umbra persists Java hint settings through `IDEPreferences`; `IDEPreferencesLiveUpdateModifier` refreshes active editors. Code Vision already opens workspace navigation actions. The command registry supplies the palette and keymap. |
| Git | GitIntelligence owns process execution and Umbra owns asynchronous status and blame. Git annotation work must stay independent of semantic hint publication. |

[JetBrains inlay hints](https://www.jetbrains.com/help/idea/inlay-hints.html) · [JetBrains SDK workflows](https://www.jetbrains.com/help/idea/sdk.html#configure-jdk-with-version-manager) · [LSP 3.17 inlay hint specification](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/language/inlayHint.md)
