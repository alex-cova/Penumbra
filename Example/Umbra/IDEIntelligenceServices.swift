import EditorIntelligence
import Penumbra

@MainActor
final class IDEIntelligenceServices {
    let symbolIndex = SymbolIndex()
    let indexingService: IndexingService
    let completionEngine: CompletionEngine
    let hoverEngine: HoverEngine
    let diagnosticEngine: DiagnosticEngine
    let navigationEngine: NavigationEngine

    init() {
        let parser = IDEWorkbenchLanguageParser()
        indexingService = IndexingService(parser: parser, index: symbolIndex)
        completionEngine = CompletionEngine(providers: [
            SymbolCompletionProvider(index: symbolIndex),
            WordCompletionProvider(index: symbolIndex),
            SnippetCompletionProvider()
        ])
        hoverEngine = HoverEngine(providers: [
            SymbolHoverProvider(index: symbolIndex)
        ])
        diagnosticEngine = DiagnosticEngine(providers: [
            DuplicateSymbolDiagnosticProvider(index: symbolIndex)
        ])
        navigationEngine = NavigationEngine(providers: [
            GoToDefinitionProvider(index: symbolIndex),
            FindReferencesProvider(index: symbolIndex)
        ])
    }

    func makeController(
        textView: TextView,
        adapter: PenumbraWorkbenchEditorAdapter,
        workspace: Workspace
    ) -> EditorIntelligenceController {
        let services = EditorIntelligenceServices(
            symbolIndex: symbolIndex,
            workspace: workspace
        )
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
        controller.onPresentNavigationChoices = { locations in
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
