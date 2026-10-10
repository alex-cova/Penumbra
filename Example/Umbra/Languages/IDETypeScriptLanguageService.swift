import EditorIntelligence
import Foundation

/// TypeScript intelligence for one window. The support object is held weakly: the service lives in
/// the registry for the window's life and must not keep what the window owns alive.
struct IDETypeScriptLanguageService: LanguageService {
    private weak var support: IDETypeScriptSupport?
    let providers: LanguageProviders

    init(support: IDETypeScriptSupport, providers: LanguageProviders) {
        self.support = support
        self.providers = providers
    }

    var name: String { "typescript" }
    var languageIdentifiers: Set<String> { [TypeScriptAnalysis.languageIdentifier] }
    var policy: LanguagePolicy { LanguagePolicy(disabling: [.symbolHover, .symbolNavigation]) }

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
