import EditorIntelligence
import Foundation
import SwiftIntelligence

/// Swift intelligence for one window. The support object is held weakly: the service lives in
/// the registry for the window's life and must not keep what the window owns alive.
struct IDESwiftLanguageService: LanguageService {
    private weak var support: IDESwiftSupport?
    let providers: LanguageProviders

    init(support: IDESwiftSupport, providers: LanguageProviders) {
        self.support = support
        self.providers = providers
    }

    var name: String { "swift" }
    var languageIdentifiers: Set<String> { [SwiftAnalysis.languageIdentifier] }

    /// The JavaScript-flavoured snippets, overload false positives and name-based guesses are all
    /// wrong for Swift: the service answers for each of them.
    var policy: LanguagePolicy {
        LanguagePolicy(disabling: [.snippets, .duplicateSymbolDiagnostics, .symbolHover, .symbolNavigation])
    }

    func start(environment: LanguageEnvironment) async {
        let lookup = environment.openBufferText
        let index = await MainActor.run { support?.index }
        await index?.setOpenBufferLookup(lookup)
        await MainActor.run { support?.setIndentUnitProvider(environment.indentUnit) }
    }

    func stop() async {
        let index = await MainActor.run { support?.index }
        await index?.setOpenBufferLookup(nil)
        await MainActor.run { support?.setIndentUnitProvider(nil) }
        await MainActor.run { support?.cancelIndexing() }
    }

    @MainActor func projectDidChange(root: URL?) {
        support?.projectDidChange(root: root)
    }

    @MainActor func filesDidChange(_ urls: [URL]) {
        support?.filesDidChange(urls)
    }

    /// A save runs the index-backed inspections again: another file's save can change what is
    /// unused here, so every open Swift document gets a fresh pass (one in flight each, the
    /// newest save cancelling the older one). Never on a keystroke.
    @MainActor func documentsDidSave(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let saved = Set(urls.map { $0.standardizedFileURL })
        let documents = support?.openSwiftDocuments?() ?? []
        // The saved files first, so what the user is looking at reports back before the rest.
        let ordered = documents.sorted { lhs, rhs in
            let left = lhs.url.map { saved.contains($0.standardizedFileURL) } ?? false
            let right = rhs.url.map { saved.contains($0.standardizedFileURL) } ?? false
            return left && !right
        }
        support?.runIndexInspections(ordered)
    }
}
