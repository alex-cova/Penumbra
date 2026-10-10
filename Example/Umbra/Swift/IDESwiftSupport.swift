import EditorIntelligence
import Foundation
import SwiftIntelligence

/// Swift indexing and providers for one window. A project or file change starts a task and
/// returns; a keystroke never waits on the index and never walks the project.
@MainActor
final class IDESwiftSupport {
    let index: SwiftIndex
    let completion: SwiftCompletionProvider
    let hover: SwiftHoverProvider
    let navigation: SwiftNavigationProvider
    let diagnostics: SwiftDiagnosticProvider
    let rename: SwiftRenameProvider
    let signatureHelp: SwiftSignatureHelpProvider
    let lineMarkers: SwiftLineMarkerProvider
    let typeHierarchy: SwiftTypeHierarchyProvider
    let callHierarchy: SwiftCallHierarchyProvider
    let codeGeneration: SwiftCodeGenerationProvider
    let structure = SwiftStructureProvider()
    let semanticTokens = SwiftSemanticTokenProvider()
    private var rebuild: Task<Void, Never>?
    private var moduleUpdate: Task<Void, Never>?

    init() {
        let index = SwiftIndex()
        self.index = index
        completion = SwiftCompletionProvider(index: index)
        hover = SwiftHoverProvider(index: index)
        navigation = SwiftNavigationProvider(index: index)
        diagnostics = SwiftDiagnosticProvider()
        rename = SwiftRenameProvider(index: index)
        signatureHelp = SwiftSignatureHelpProvider(index: index)
        lineMarkers = SwiftLineMarkerProvider(index: index)
        typeHierarchy = SwiftTypeHierarchyProvider(index: index)
        callHierarchy = SwiftCallHierarchyProvider(index: index)
        codeGeneration = SwiftCodeGenerationProvider(index: index)
    }

    var languageService: IDESwiftLanguageService {
        IDESwiftLanguageService(
            support: self,
            providers: LanguageProviders(
                completion: [completion],
                hover: [hover],
                diagnostics: [diagnostics],
                navigation: [navigation],
                signatureHelp: signatureHelp,
                codeActions: SwiftCodeActionProvider(),
                rename: rename,
                codeGeneration: codeGeneration,
                breadcrumbs: structure,
                semanticTokens: semanticTokens,
                lineMarkers: lineMarkers,
                structure: structure,
                typeHierarchy: typeHierarchy,
                callHierarchy: callHierarchy
            )
        )
    }

    func projectDidChange(root: URL?) {
        rebuild?.cancel()
        rebuild = Task { await index.setRoot(root) }
    }

    func filesDidChange(_ urls: [URL]) {
        let sources = urls.filter { SwiftPaths.isSourceFile($0) }
        guard !sources.isEmpty else { return }
        Task { await index.applyFileChanges(sources) }
    }

    /// Tells the index which module each file belongs to. Updates run in the order they were
    /// made, so a slow earlier one cannot land after a later one.
    func setModuleResolver(_ resolver: (@Sendable (URL) -> String?)?) {
        let previous = moduleUpdate
        let index = index
        moduleUpdate = Task {
            _ = await previous?.value
            await index.setModuleResolver(resolver)
        }
    }

    func cancelIndexing() {
        rebuild?.cancel()
        rebuild = nil
    }
}
