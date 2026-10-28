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
    /// One index-inspection pass per file in flight; a newer trigger cancels the older one.
    private var indexTasks: [URL: Task<Void, Never>] = [:]
    /// Bumped on every trigger so an older trigger's buffered run cannot publish over a newer one.
    private var indexGeneration = 0
    /// Called with each finished index pass's diagnostics for one file (empty when it is clean).
    @ObservationIgnored var onInspectionDiagnostics: (@MainActor (URL, [Diagnostic]) -> Void)?
    /// The window's open Swift documents, read when a save asks for a fresh project-wide pass.
    /// The closure does not retain the window.
    var openSwiftDocuments: (@MainActor () -> [EditorIntelligence.Document])?

    /// True while SourceKit-LSP offers code actions, so the native "Extract method" ⌥↩ entry stays
    /// hidden and the two never show twice. The host injects a closure reading its connection box.
    private let sourceKitOffersCodeActions: @Sendable () -> Bool

    init(activity: IDEIndexActivity = IDEIndexActivity(), sourceKitOffersCodeActions: @escaping @Sendable () -> Bool = { false }) {
        self.sourceKitOffersCodeActions = sourceKitOffersCodeActions
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
        inspections.setIndexLookup(index)
        inspections.setIndexResultHandler { [weak self] url, diagnostics in
            Task { @MainActor [weak self] in self?.onInspectionDiagnostics?(url, diagnostics) }
        }
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
                codeActions: SwiftCodeActionProvider(
                    inspections: inspections, sourceKitOffersCodeActions: sourceKitOffersCodeActions),
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

    /// Returns once the index has read the project (or at once when it is not reading). The project-wide inspections
    /// ask it for names, and an index still being built would make everything look unused.
    func waitForIndex() async {
        await rebuild?.value
    }

    func cancelIndexing() {
        rebuild?.cancel()
        rebuild = nil
        indexGeneration += 1
        for task in indexTasks.values { task.cancel() }
        indexTasks.removeAll()
    }

    /// Runs the index-backed inspections for `documents` (a save, an open or a profile change —
    /// never a keystroke). One pass per document is in flight, and a newer call cancels the older
    /// one. Every open buffer lands in the index before any pass asks it who mentions a name, so a
    /// call added in another file clears the finding when that file is saved.
    func runIndexInspections(_ documents: [EditorIntelligence.Document]) {
        var items: [(key: URL, url: URL, text: String)] = []
        for document in documents {
            guard document.languageIdentifier == SwiftAnalysis.languageIdentifier,
                  !document.isDependencySource,
                  let url = document.url else { continue }
            // File-backed documents are elided (their text stays in the editor); read through
            // the ranged reader like Java's `fullText` does.
            items.append((url.standardizedFileURL, url, Self.fullText(of: document)))
        }
        guard !items.isEmpty else { return }
        indexGeneration += 1
        let generation = indexGeneration
        for item in items { indexTasks[item.key]?.cancel() }
        Task {
            for item in items {
                await index.noteOpenDocument(url: item.url, text: item.text)
                if Task.isCancelled { return }
            }
            guard generation == indexGeneration, !Task.isCancelled else { return }
            for item in items {
                indexTasks[item.key] = Task {
                    await inspections.runIndexInspections(for: item.url, text: item.text)
                }
            }
        }
    }

    /// The document's whole text: the snapshot's when materialized, else through its ranged
    /// reader (file-backed documents are elided by design).
    private static func fullText(of document: EditorIntelligence.Document) -> String {
        if let text = document.contentSnapshot.text { return text }
        let length = document.contentSnapshot.utf16Length
        guard length > 0 else { return "" }
        return document.substring(utf16Offset: 0, length: length)
    }

    /// Runs the pass for one file's text: the same, without a document (tests and single-file callers).
    func runIndexInspections(for url: URL, text: String) {
        let key = url.standardizedFileURL
        indexTasks[key]?.cancel()
        indexTasks[key] = Task {
            await index.noteOpenDocument(url: url, text: text)
            await inspections.runIndexInspections(for: url, text: text)
        }
    }

    /// The indentation unit the formatter lays code out with, from the editor's settings.
    func setIndentUnitProvider(_ provider: (@Sendable () async -> String)?) {
        Task { await formatting.setIndentUnitProvider(provider) }
    }
}
