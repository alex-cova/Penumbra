import EditorIntelligence
import Foundation

/// Whether decompiling a `.class` file with no attached source (Sunflower/FernflowerKit) is
/// allowed for one resolve. `.ask` fires the request at most once even if several candidate
/// members within the same navigation would each need to decompile.
actor JavaDecompileGate {
    enum Policy: Sendable {
        case allowed
        case denied
        case ask(@Sendable () async -> Bool)
    }

    private let policy: Policy
    private var resolved: Bool?

    init(policy: Policy) {
        self.policy = policy
    }

    func allow() async -> Bool {
        switch policy {
        case .allowed:
            return true
        case .denied:
            return false
        case .ask(let request):
            if let resolved { return resolved }
            let accepted = await request()
            resolved = accepted
            return accepted
        }
    }

    /// Whether `.ask` was answered yes at least once, so the caller can persist that as standing
    /// consent. False for `.allowed`/`.denied`, which never change consent state.
    var didAcceptJustNow: Bool {
        get async { resolved == true }
    }
}

/// Go to Definition for Java. Runs ahead of the generic name search, which Umbra configures to
/// skip Java so a symbol this can't resolve doesn't jump to an unrelated hit of the same name.
public actor JavaGoToDefinitionProvider: NavigationProvider {
    public let name = "JavaGoToDefinition"
    private let index: JavaIndex
    private let indexPaths: JavaIndexPaths
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    private var jdkHome: URL?
    private var openBuffer: (@Sendable (URL) async -> String?)?
    private var decompilerAccepted = false
    private var decompilerConsentRequest: (@Sendable () async -> Bool)?

    public init(index: JavaIndex, indexPaths: JavaIndexPaths) {
        self.index = index
        self.indexPaths = indexPaths
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

    public func setJDKHome(_ home: URL?) {
        jdkHome = home
    }

    /// Live text of open editors, keyed by file URL. Nil means the file is not open; the resolver
    /// reads disk. Used so a dirty buffer wins over the copy that was indexed.
    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    /// `accepted` is the standing consent (restored from a preference) for decompiling `.class`
    /// files with Sunflower. `request` shows the agreement and returns whether the user accepted;
    /// it is only ever invoked for a manually-triggered navigation (never for Cmd-hover), and at
    /// most once until it returns true, after which `accepted` is treated as true from then on.
    public func setDecompilerConsent(accepted: Bool, request: (@Sendable () async -> Bool)?) {
        decompilerAccepted = accepted
        decompilerConsentRequest = request
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        guard context.kind == .definition else { return nil }
        guard context.document.languageIdentifier == "java" else { return nil }
        let source = JavaNavigationText.fullText(of: context.document)
        guard !source.isEmpty else { return nil }
        let utf16Offset = context.cursor.position.utf16Offset
        let lookup = openBuffer
        let home = jdkHome
        let cacheRoot = indexPaths.root
        let gate = JavaDecompileGate(policy: decompilePolicy(trigger: context.trigger))
        let resolve = {
            await JavaGoToDefinition.resolve(
                source: source,
                fileURL: context.document.url,
                utf16Offset: utf16Offset,
                index: self.index,
                jdkHome: home,
                cacheRoot: cacheRoot,
                openBuffer: lookup,
                decompile: gate
            )
        }
        let hits: [JavaDefinitionHit]
        if let scope = scope(for: context.document.url) {
            hits = await JavaIndex.$queryScope.withValue(scope) {
                await JavaMemberLookup.$sourceTextProvider.withValue(lookup) {
                    await resolve()
                }
            }
        } else {
            hits = await JavaMemberLookup.$sourceTextProvider.withValue(lookup) {
                await resolve()
            }
        }
        if await gate.didAcceptJustNow {
            decompilerAccepted = true
        }
        return navigationResult(hits, in: context.document)
    }

    /// Hover (trigger `.idle`) never prompts — an underline-on-hover shouldn't pop a dialog. Only
    /// a manual Go to Definition (Cmd-click, ⌘B, the palette) can ask.
    private func decompilePolicy(trigger: RequestTrigger) -> JavaDecompileGate.Policy {
        if decompilerAccepted { return .allowed }
        guard trigger == .manual, let decompilerConsentRequest else { return .denied }
        return .ask(decompilerConsentRequest)
    }

    private func scope(for file: URL?) -> Set<String>? {
        guard let file, let classpathModel, let classpathPaths else { return nil }
        return classpathModel.visibleShardPaths(forFile: file, paths: classpathPaths)
    }

    private func navigationResult(_ hits: [JavaDefinitionHit], in document: Document) -> NavigationResult? {
        let locations = hits.map { hit -> Location in
            let same = JavaNavigationText.sameFile(hit.url, document.url) || hit.url == nil
            return Location(
                documentID: same ? document.id : DocumentID(),
                url: hit.url,
                range: hit.range,
                displayName: hit.displayName
            )
        }
        switch locations.count {
        case 0: return nil
        case 1: return .single(locations[0])
        default: return .multiple(locations)
        }
    }
}
