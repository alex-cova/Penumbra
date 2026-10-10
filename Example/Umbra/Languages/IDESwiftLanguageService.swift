import EditorIntelligence
import Foundation

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
    }

    func stop() async {
        let index = await MainActor.run { support?.index }
        await index?.setOpenBufferLookup(nil)
        await MainActor.run { support?.cancelIndexing() }
    }

    @MainActor func projectDidChange(root: URL?) {
        support?.projectDidChange(root: root)
    }

    @MainActor func filesDidChange(_ urls: [URL]) {
        support?.filesDidChange(urls)
    }
}
