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
    var tier: LanguageServiceTier { base.tier }
    var unavailableFeatures: Set<LanguageFeature> { base.unavailableFeatures }

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

    /// A save rechecks every open Java file. One that did not change can still break because a
    /// file it depends on did.
    @MainActor func documentsDidSave(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let documents = support?.openJavaDocuments?() ?? []
        support?.compileNow(documents, force: true)
    }

    /// The pause after an edit: the name and role indexes see the unsaved buffer, and one
    /// unambiguous import is proposed when the policy asks for it.
    @MainActor func bufferDidSettle(_ request: BufferSettleRequest) async -> [TextEdit] {
        guard let support else { return [] }
        if let url = request.url {
            await support.nameIndex.setOverlay(url, text: request.text)
            await support.roleIndex.setOverlay(url, text: request.text)
        }
        guard !request.suppressEdits else { return [] }
        let policy = support.importPolicy
        let pasting = request.pastedText != nil && policy.insertImportsOnPaste == .always
        guard policy.addUnambiguousImportsOnTheFly || pasting else { return [] }
        if pasting, let paste = request.pastedText {
            return await support.importEdits(forPastedText: paste, in: request.text, file: request.url, policy: policy)
        }
        return await support.importEdits(
            in: request.text, caretUTF16: request.caretUTF16, file: request.url, policy: policy
        )
    }
}
