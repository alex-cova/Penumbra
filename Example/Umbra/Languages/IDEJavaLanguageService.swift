import EditorIntelligence
import Foundation
import JavaIntelligence

/// `JavaLanguageService` plus what only the host can do for it: the window's folder and file changes
/// reach `IDEJavaSupport`, which retargets the index and re-indexes what changed. Everything else
/// is the library service, unchanged.
///
/// The support object is held weakly: the service lives in the registry for the window's life and
/// must not keep what the window owns alive.
struct IDEJavaLanguageService: LanguageService {
    let base: JavaLanguageService
    private weak var support: IDEJavaSupport?

    init(base: JavaLanguageService, support: IDEJavaSupport) {
        self.base = base
        self.support = support
    }

    var name: String { base.name }
    var languageIdentifiers: Set<String> { base.languageIdentifiers }
    var providers: LanguageProviders { base.providers }
    var policy: LanguagePolicy { base.policy }

    func start(environment: LanguageEnvironment) async {
        await base.start(environment: environment)
    }

    func stop() async {
        await base.stop()
    }

    @MainActor func projectDidChange(root: URL?) {
        support?.projectDidChange(root: root)
    }

    @MainActor func filesDidChange(_ urls: [URL]) {
        support?.filesDidChange(urls)
    }
}
