import EditorIntelligence
import JavaIntelligence
import Penumbra

@MainActor
final class IDEIntelligenceServices {
    let symbolIndex = SymbolIndex()
    let indexingService: IndexingService
    let completionEngine: CompletionEngine
    let hoverEngine: HoverEngine
    let diagnosticEngine: DiagnosticEngine
    let navigationEngine: NavigationEngine
    /// Java-specific indexing (JDK + project sources), completion and parameter info, independent
    /// of the generic `symbolIndex`/`indexingService` above. `JavaCompletionProvider` claims
    /// `.java` documents as the primary provider, so the engine only falls back to the generic
    /// Symbol/Word results when it has nothing (in comments and strings) and never after a `.`.
    let javaSupport = IDEJavaSupport()
    /// `@file` references in Markdown. The window sets its file source (`setSource`).
    let markdownFileMentions = MarkdownFileMentionCompletionProvider()
    /// `{{ }}`, methods, headers, and `# @` flags in `.http` files. The window sets the global store.
    let httpCompletion = HTTPCompletionProvider()

    /// Every language's intelligence, routed by the document's language: Java, the app's Run actions
    /// for Java files, `@file` mentions in Markdown, `.http` completion and JSON formatting. The order
    /// is the order each engine asks its providers, and the order services that share a language are
    /// combined in (Java's code actions come before the Run ones).
    let languages: LanguageServiceRegistry

    init() {
        let parser = IDEWorkbenchLanguageParser()
        indexingService = IndexingService(parser: parser, index: symbolIndex)
        let languages = LanguageServiceRegistry(services: [
            javaSupport.languageService,
            BasicLanguageService(
                name: "umbra.run", languageIdentifiers: ["java"],
                providers: LanguageProviders(codeActions: IDERunCodeActionProvider())
            ),
            BasicLanguageService(
                name: "umbra.markdown-mentions", languageIdentifiers: ["markdown"],
                providers: LanguageProviders(completion: [markdownFileMentions])
            ),
            BasicLanguageService(
                name: "umbra.http", languageIdentifiers: ["http"],
                providers: LanguageProviders(completion: [httpCompletion]),
                policy: LanguagePolicy(disabling: [.snippets, .duplicateSymbolDiagnostics])
            ),
            BasicLanguageService(
                name: "umbra.json", languageIdentifiers: ["json"],
                providers: LanguageProviders(formatting: IDEJSONFormattingProvider(indentUnit: { await IDEPreferences.currentIndentUnit() }))
            )
        ])
        self.languages = languages
        // The generic, name-based providers come first for completion and diagnostics and last for
        // hover and navigation; each skips the languages whose service opted out of it.
        completionEngine = CompletionEngine(providers: [
            SymbolCompletionProvider(index: symbolIndex),
            WordCompletionProvider(index: symbolIndex),
            SnippetCompletionProvider(excludedLanguageIdentifiers: languages.identifiers(disabling: .snippets))
        ] + languages.completionProviders)
        hoverEngine = HoverEngine(providers: languages.hoverProviders + [
            SymbolHoverProvider(index: symbolIndex, skippingLanguages: Array(languages.identifiers(disabling: .symbolHover)))
        ])
        diagnosticEngine = DiagnosticEngine(providers: [
            DuplicateSymbolDiagnosticProvider(
                index: symbolIndex, skippingLanguages: Array(languages.identifiers(disabling: .duplicateSymbolDiagnostics))
            )
        ] + languages.diagnosticProviders)
        let symbolNavigationSkips = Array(languages.identifiers(disabling: .symbolNavigation))
        navigationEngine = NavigationEngine(providers: languages.navigationProviders + [
            GoToDefinitionProvider(index: symbolIndex, skippingLanguages: symbolNavigationSkips),
            FindReferencesProvider(index: symbolIndex, skippingLanguages: symbolNavigationSkips)
        ])
    }

    func makeController(
        textView: TextView,
        adapter: PenumbraWorkbenchEditorAdapter,
        workspace: Workspace
    ) -> EditorIntelligenceController {
        let services = EditorIntelligenceServices(languages: languages, symbolIndex: symbolIndex, workspace: workspace)
        let controller = EditorIntelligenceController(
            textView: textView,
            adapter: adapter,
            completionEngine: completionEngine,
            hoverEngine: hoverEngine,
            diagnosticEngine: diagnosticEngine,
            navigationEngine: navigationEngine,
            services: services
        )
        controller.onOpenLocationInOtherDocument = { location in
            IDEIntelligenceServices.openLocation(location, adapter: adapter)
        }
        controller.onPresentNavigationChoices = { _, locations in
            // Present first match when no picker is wired.
            if let first = locations.first {
                _ = IDEIntelligenceServices.openLocation(first, adapter: adapter)
            }
        }
        return controller
    }

    @MainActor
    static func openLocation(_ location: Location, adapter: PenumbraWorkbenchEditorAdapter) -> Bool {
        let documentID = location.documentID
        let workbench = adapter.workbench
        guard let pane = workbench.panes.first(where: { pane in
            pane.documents.contains { $0.documentID == documentID }
        }) else {
            return false
        }
        workbench.activatePane(pane.id)
        guard let document = pane.documents.first(where: { $0.documentID == documentID }) else {
            return false
        }
        pane.selectDocument(document.id)
        guard let textView = adapter.textView else { return false }
        adapter.bindNavigationHistory(to: textView, document: document)
        let range = TextEditApplicator.nsRange(for: location.range, in: textView)
        textView.selectedRanges = [range]
        textView.scrollRangeToVisible(range)
        _ = textView.focusTextInput()
        return true
    }
}
