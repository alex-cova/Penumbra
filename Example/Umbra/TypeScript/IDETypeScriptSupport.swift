import EditorIntelligence
import Foundation

/// TypeScript indexing and providers for one window. A project or file change starts a task and
/// returns; a keystroke never waits on the index and never walks the project.
@MainActor
final class IDETypeScriptSupport {
    let index: TypeScriptIndex
    let completion: TypeScriptCompletionProvider
    let hover: TypeScriptHoverProvider
    let navigation: TypeScriptNavigationProvider
    let diagnostics: TypeScriptDiagnosticProvider
    let rename: TypeScriptRenameProvider
    let structure = TypeScriptStructureProvider()
    let semanticTokens = TypeScriptSemanticTokenProvider()
    private var rebuild: Task<Void, Never>?

    init() {
        let index = TypeScriptIndex()
        let cache = TypeScriptAnalysis.makeCache()
        self.index = index
        completion = TypeScriptCompletionProvider(cache: cache, index: index)
        hover = TypeScriptHoverProvider(cache: cache, index: index)
        navigation = TypeScriptNavigationProvider(cache: cache, index: index)
        diagnostics = TypeScriptDiagnosticProvider(cache: cache)
        rename = TypeScriptRenameProvider(cache: cache, index: index)
    }

    var languageService: IDETypeScriptLanguageService {
        IDETypeScriptLanguageService(
            support: self,
            providers: LanguageProviders(
                completion: [completion],
                hover: [hover],
                diagnostics: [diagnostics],
                navigation: [navigation],
                rename: rename,
                breadcrumbs: structure,
                semanticTokens: semanticTokens,
                structure: structure
            )
        )
    }

    func projectDidChange(root: URL?) {
        rebuild?.cancel()
        rebuild = Task { await index.setRoot(root) }
    }

    func filesDidChange(_ urls: [URL]) {
        let sources = urls.filter { TypeScriptPaths.isSourceFile($0) }
        guard !sources.isEmpty else { return }
        Task { await index.applyFileChanges(sources) }
    }

    func cancelIndexing() {
        rebuild?.cancel()
        rebuild = nil
    }
}
