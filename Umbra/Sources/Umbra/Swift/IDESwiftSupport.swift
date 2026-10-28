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
    let refactoring: SwiftRefactoringProvider
    let inspections: SwiftInspectionService
    /// The window's active Swift inspection profile as the editor's analysis reads it (off the main actor).
    let inspectionResolver = IDESwiftInspectionResolver()
    let rename: SwiftRenameProvider
    let signatureHelp: SwiftSignatureHelpProvider
    let formatting = SwiftFormattingProvider()
    let lineMarkers: SwiftLineMarkerProvider
    let typeHierarchy: SwiftTypeHierarchyProvider
    let callHierarchy: SwiftCallHierarchyProvider
    let codeGeneration: SwiftCodeGenerationProvider
    let structure = SwiftStructureProvider()
    let semanticTokens = SwiftSemanticTokenProvider()
    private var rebuild: Task<Void, Never>?
    private var moduleUpdate: Task<Void, Never>?
    private let activity: IDEIndexActivity

    init(activity: IDEIndexActivity = IDEIndexActivity()) {
        self.activity = activity
        let index = SwiftIndex()
        self.index = index
        completion = SwiftCompletionProvider(index: index)
        hover = SwiftHoverProvider(index: index)
        navigation = SwiftNavigationProvider(index: index)
        diagnostics = SwiftDiagnosticProvider()
        // The options are asked for on every analysis, per file, so a profile change needs no plumbing into the service.
        let resolver = inspectionResolver
        inspections = SwiftInspectionService(optionsForFile: { resolver.options(for: $0) })
        rename = SwiftRenameProvider(index: index)
        refactoring = SwiftRefactoringProvider(index: index)
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
                diagnostics: [diagnostics, SwiftInspectionDiagnosticProvider(service: inspections)],
                navigation: [navigation],
                formatting: formatting,
                signatureHelp: signatureHelp,
                codeActions: SwiftCodeActionProvider(inspections: inspections),
                rename: rename,
                refactoring: refactoring,
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
        // Marked before the task starts: until the walk's first line runs the index looks empty, not unbuilt.
        let token = activity.begin(.swift)
        rebuild = Task { [activity] in
            defer { activity.end(token) }
            await index.setRoot(root)
        }
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

    /// The indentation unit the formatter lays code out with, from the editor's settings.
    func setIndentUnitProvider(_ provider: (@Sendable () async -> String)?) {
        Task { await formatting.setIndentUnitProvider(provider) }
    }
}
