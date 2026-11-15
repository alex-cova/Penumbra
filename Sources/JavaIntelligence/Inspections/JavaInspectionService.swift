import EditorIntelligence
import Foundation

/// One static analysis warning surfaced in the Problems panel.
public struct JavaInspection: Sendable, Hashable {
    public enum Severity: String, Sendable, CaseIterable, Codable {
        case error
        case warning
        case weakWarning
        /// IntelliJ's "Consideration".
        case info
        /// IntelliJ's "No highlighting (fix available)": nothing is drawn or listed, but the quick
        /// fix stays on ⌥↩ (`JavaInspectionService.quietFindings`).
        case noHighlighting
    }

    public let id: String
    public let message: String
    public let severity: Severity
    public let range: EditorIntelligence.TextRange
    public let fixTitle: String?

    public init(id: String, message: String, severity: Severity, range: EditorIntelligence.TextRange, fixTitle: String? = nil) {
        self.id = id
        self.message = message
        self.severity = severity
        self.range = range
        self.fixTitle = fixTitle
    }

    func withSeverity(_ severity: Severity) -> JavaInspection {
        JavaInspection(id: id, message: message, severity: severity, range: range, fixTitle: fixTitle)
    }

    public func asDiagnostic() -> Diagnostic {
        Diagnostic(
            id: UUID(),
            severity: severity.diagnosticSeverity,
            message: message,
            range: range,
            source: "java-inspection",
            code: id
        )
    }
}

extension JavaInspection.Severity {
    var diagnosticSeverity: DiagnosticSeverity {
        switch self {
        case .error: return .error
        case .warning: return .warning
        case .weakWarning: return .hint
        case .info: return .information
        case .noHighlighting: return .hint
        }
    }
}

/// Debounced static inspections for open Java files.
public actor JavaInspectionService: DiagnosticProvider {
    public nonisolated let name = "java-inspection"

    private let index: JavaIndex
    private let parseCache: JavaDocumentParseCache
    /// Each file's module context (scope, required shards, JPMS visibility), shared with
    /// `JavaBatchInspector` so the editor and Inspect Code judge a file the same way.
    private var scopes = JavaFileResolutionScopes.none
    private var profile: JavaInspectionProfile
    private var classifier = JavaInspectionFileClassifier()
    private var languageLevelResolver: (@Sendable (URL) -> Int?)?
    private let usageProvider: JavaFindUsagesProvider?
    /// Project-wide findings per file, valid for the text they were computed from.
    private var projectResults: [URL: (hash: Int, inspections: [JavaInspection])] = [:]
    private var idleDelay: Duration
    private var cache: [URL: CachedResult] = [:]
    private var pending: [URL: Task<Void, Never>] = [:]
    /// The text and index sources each pending task was scheduled for: a refresh for the same
    /// text against the same sources skips scheduling whether the pass is still waiting or already
    /// running. New sources supersede it like new text does.
    private var pendingKey: [URL: AnalysisKey] = [:]
    private var resultHandler: (@Sendable (URL, [Diagnostic]) -> Void)?
    /// The newest key asked for per file. Only a pass for it may publish: an older text, or the
    /// same text against older sources or another classpath, that finishes last is dropped.
    private var latestKey: [URL: AnalysisKey] = [:]
    /// Bumped whenever something every result depends on besides the text and the index changes:
    /// the module model (every file's scope), the profile, the language level resolver. A pass
    /// that started under the old value is then never current, even if it finishes after the
    /// change cleared the cache.
    private var contextVersion = 0
    /// Passes that ran every stage uncancelled, published or not, and passes a newer request
    /// cancelled (they stop at the next stage boundary). For tests and measurements.
    private(set) var completedPasses = 0
    private(set) var cancelledPasses = 0
    /// Passes dropped because the index or the context changed while they ran.
    private(set) var straddledPasses = 0

    /// Waits until no pass is queued or running. For tests: `analyzeNow` joins a pass already
    /// queued for the same key without waiting for it.
    func settle() async {
        while let (url, task) = pending.first {
            await task.value
            // A pass releases its own entry, but one cancelled before it ran cannot. A finished
            // task left registered would make this loop await it again forever.
            if pending[url] == task {
                pending[url] = nil
                pendingKey[url] = nil
            }
        }
    }

    /// Passes queued or running. For tests.
    var pendingPassCount: Int { pending.count }

    /// What a result is valid for. Findings depend on the text, on what the index holds
    /// (`unresolved-type` claims a class does not exist) and on the file's module scope, so a
    /// result is current only for this text against this ``JavaIndex/sourcesVersion``, these
    /// open-buffer declarations and this classpath. A body edit in another buffer does not move
    /// it (``JavaIndex/overlayDeclarationsVersion`` only follows declarations).
    private struct AnalysisKey: Equatable {
        let textHash: Int
        let sourcesVersion: Int
        /// ``JavaIndex/overlayDeclarationsVersion``: what other open buffers declare, unsaved.
        let overlayVersion: Int
        let contextVersion: Int
    }

    private struct CachedResult {
        let key: AnalysisKey
        let diagnostics: [Diagnostic]
        /// Findings set to "No highlighting (fix available)".
        let quiet: [Diagnostic]
        /// Why the index could not prove absence for this file (`nil`: it could), so "cannot
        /// resolve" rules were not judged: uncertainty, not a clean bill.
        let resolution: JavaResolutionReadiness?
        var resolutionPending: Bool { resolution != nil }

        var textHash: Int { key.textHash }
    }

    private func key(for text: String) async -> AnalysisKey {
        AnalysisKey(
            textHash: text.hashValue, sourcesVersion: await index.sourcesVersion,
            overlayVersion: await index.overlayDeclarationsVersion, contextVersion: contextVersion
        )
    }

    public init(
        index: JavaIndex,
        parseCache: JavaDocumentParseCache = JavaDocumentParseCache(),
        enabledRules: Set<JavaInspectionRule> = JavaInspectionRule.enabledByDefault,
        idleDelay: Duration = .milliseconds(800),
        usageProvider: JavaFindUsagesProvider? = nil
    ) {
        self.usageProvider = usageProvider
        self.index = index
        self.parseCache = parseCache
        var profile = JavaInspectionProfile.standard()
        profile.disabled = Set(JavaInspectionRule.allCases.filter { !enabledRules.contains($0) }.map(\.code))
        self.profile = profile
        self.idleDelay = idleDelay
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        let next = JavaFileResolutionScopes(model: model, paths: model == nil ? nil : indexPaths)
        guard next != scopes else { return }
        scopes = next
        // Every file's scope may have moved: what was judged against the old one is stale.
        contextVersion += 1
    }

    /// The module contexts files are judged against, for a batch run that must agree with this
    /// service (`JavaBatchInspector(resolutionScopes:)`).
    public var resolutionScopes: JavaFileResolutionScopes { scopes }

    /// How long the file must rest before it is analyzed again (IntelliJ's "Autoreparse delay").
    public func setIdleDelay(_ delay: Duration) { idleDelay = delay }

    /// The choices every file is analyzed with: rules, severities (with their per-scope
    /// exceptions), thresholds and project-rule options. `projectRoot` and `testRoots` let scoped
    /// overrides tell which files are tests.
    public func setProfile(_ newProfile: JavaInspectionProfile, projectRoot: URL? = nil, testRoots: [URL] = []) {
        let newClassifier = JavaInspectionFileClassifier(projectRoot: projectRoot, testRoots: testRoots)
        guard newProfile != profile || newClassifier != classifier else { return }
        if newProfile.projectOptions != profile.projectOptions { projectResults.removeAll() }
        profile = newProfile
        classifier = newClassifier
        contextVersion += 1
        cache.removeAll()
    }

    public var currentProfile: JavaInspectionProfile { profile }

    /// Tells the Java language level of a file (its module's, else the JDK's), for the rules that
    /// suggest newer syntax. Without one they report nothing.
    ///
    /// `identity` names what the resolver answers (Umbra: the JDK's feature version and each
    /// module's level). A resolver with the identity already in effect changes nothing, so the
    /// cache is kept; without an identity every call counts as a change, as before.
    public func setLanguageLevelResolver(_ resolver: (@Sendable (URL) -> Int?)?, identity: String? = nil) {
        if let identity, identity == languageLevelIdentity, (resolver == nil) == (languageLevelResolver == nil) { return }
        languageLevelResolver = resolver
        languageLevelIdentity = identity
        contextVersion += 1
        cache.removeAll()
    }

    private var languageLevelIdentity: String?

    public func setEnabledRules(_ rules: Set<JavaInspectionRule>) {
        var updated = profile
        updated.disabled = Set(JavaInspectionRule.allCases.filter { !rules.contains($0) }.map(\.code))
        setProfile(updated, projectRoot: classifier.projectRoot, testRoots: classifier.testRoots.map { URL(fileURLWithPath: $0) })
    }

    /// Severity per rule where the user changed it from the rule's default.
    public func setSeverityOverrides(_ overrides: [JavaInspectionRule: JavaInspection.Severity]) {
        var updated = profile
        updated.severities = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.code, $0.value.rawValue) })
        setProfile(updated, projectRoot: classifier.projectRoot, testRoots: classifier.testRoots.map { URL(fileURLWithPath: $0) })
    }

    /// The numbers behind the metric rules (complexity, nesting, parameter count, lengths).
    public func setThresholds(_ thresholds: JavaInspectionThresholds) {
        var updated = profile
        updated.limits = Dictionary(uniqueKeysWithValues: thresholds.values.map { ($0.key.code, $0.value) })
        setProfile(updated, projectRoot: classifier.projectRoot, testRoots: classifier.testRoots.map { URL(fileURLWithPath: $0) })
    }

    public func setProjectOptions(_ options: JavaProjectInspectionOptions) {
        var updated = profile
        updated.treatsPublicApiAsUsed = options.treatsPublicApiAsUsed
        setProfile(updated, projectRoot: classifier.projectRoot, testRoots: classifier.testRoots.map { URL(fileURLWithPath: $0) })
    }

    /// Runs the rules that need usages from the whole project (unused declarations, access that
    /// can be weaker, return values nobody reads, parameters that never vary) for one file and
    /// folds their findings into the file's diagnostics. Meant for a save or an index change: one
    /// usage search per declaration. The findings are dropped as soon as the text changes.
    public func runProjectInspections(for document: Document) async {
        guard let usageProvider, document.languageIdentifier == "java", let url = document.url,
              !document.isDependencySource else { return }
        let enabled = profile.enabledRules(in: classifier.context(for: url))
        guard !enabled.isDisjoint(with: JavaInspectionRegistry.projectRules) else { return }
        let text = JavaNavigationText.fullText(of: document)
        let hash = text.hashValue
        let resolution = scopes.context(for: url)
        let options = profile.projectOptions
        let found: [JavaInspection]? = await resolution.apply {
            guard let tree = await tree(for: document, text: text) else { return nil }
            return await JavaProjectInspector.inspect(
                source: text, url: url, tree: tree, provider: usageProvider, enabled: enabled, options: options
            )
        }
        // No tree means nothing was analysed: keep what is stored rather than record "none".
        guard !Task.isCancelled, let found else { return }
        projectResults[url] = (hash, found)
        await analyzeNow(document, force: true)
    }

    /// The shared incremental tree, also read by the syntax-error provider built in
    /// `JavaLanguageService`. This only wraps the immutable `parseCache` let (an actor, whose
    /// references are safe to share), so it can be read synchronously from `init`.
    public nonisolated var documentParseCache: JavaDocumentParseCache { parseCache }

    public func setResultHandler(_ handler: (@Sendable (URL, [Diagnostic]) -> Void)?) {
        resultHandler = handler
    }

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        guard document.languageIdentifier == "java", let url = document.url, !document.isDependencySource else { return [] }
        let text = JavaNavigationText.fullText(of: document)
        let key = await key(for: text)
        latestKey[url] = key
        if let cached = cache[url], cached.key == key { return cached.diagnostics }
        scheduleAnalysis(url: url, text: text, key: key, document: document)
        return cache[url]?.diagnostics ?? []
    }

    /// Whether the cached result is for exactly this text. `document.text` is empty for
    /// elided file-backed documents, so this hashes the full text like the analysis does.
    /// A result computed against other index sources is stale too.
    public func isFresh(_ document: Document) async -> Bool {
        if document.isDependencySource { return true }
        guard document.languageIdentifier == "java", let url = document.url else { return false }
        return cache[url]?.key == (await key(for: JavaNavigationText.fullText(of: document)))
    }

    /// Whether `url`'s current result was computed while the index could not prove a class
    /// missing (JDK, project sources or a classpath root of its module not indexed yet, or a build
    /// model still unknown). Its "cannot resolve" findings are then unknown, not absent.
    public func isResolutionPending(for url: URL) -> Bool {
        cache[url]?.resolutionPending ?? false
    }

    /// What `url`'s current result could not judge, and why; `nil` when it was authoritative (or
    /// there is no result). The host turns it into "pending" while indexing runs and
    /// "unavailable" once nothing more will arrive.
    public func resolutionReadiness(for url: URL) -> JavaResolutionReadiness? {
        cache[url]?.resolution
    }

    /// The index published new sources (or the module model changed): re-judge each of
    /// `documents` whose result is no longer current. Goes through the cancellable schedule, so a
    /// burst of publishes coalesces: a newer publish cancels the pass an older one queued, and a
    /// file whose result is current is skipped. Project-wide rules wait for the next save.
    public func refreshAfterIndexChange(_ documents: [Document]) async {
        for document in documents {
            guard document.languageIdentifier == "java", let url = document.url, !document.isDependencySource else { continue }
            let text = JavaNavigationText.fullText(of: document)
            let key = await key(for: text)
            latestKey[url] = key
            if cache[url]?.key == key { continue }
            scheduleAnalysis(url: url, text: text, key: key, document: document)
        }
    }

    public func diagnosticsWithFreshness(for document: Document) async -> (diagnostics: [Diagnostic], staleSources: Set<String>) {
        let diagnostics = await diagnostics(for: document)
        return (diagnostics, await isFresh(document) ? [] : ["java-inspection"])
    }

    /// The findings of `url` set to "No highlighting (fix available)". They are not published as
    /// diagnostics; the code-action provider asks for them so their fixes stay on ⌥↩.
    public func quietFindings(for url: URL) -> [Diagnostic] {
        cache[url]?.quiet ?? []
    }

    /// Analyses `document` unless its result is current. `force` re-runs a current one. A result
    /// computed against older index sources is not current, so a host that calls this after it
    /// published new sources gets every "cannot resolve" re-judged against them.
    public func analyzeNow(_ document: Document, force: Bool = false) async {
        guard document.languageIdentifier == "java", let url = document.url, !document.isDependencySource else { return }
        let text = JavaNavigationText.fullText(of: document)
        let key = await key(for: text)
        latestKey[url] = key
        if !force, cache[url]?.key == key { return }
        // A pass for this exact text and these sources is already waiting or running: joining it
        // beats cancelling and restarting it.
        if !force, pendingKey[url] == key { return }
        // The cancelled pass stops at its next boundary and, its key gone, never releases itself:
        // drop it here so nothing is left registered for a task that is finished.
        pending[url]?.cancel()
        pending[url] = nil
        pendingKey[url] = nil
        await runAnalysis(url: url, text: text, key: key, document: document)
    }

    private func scheduleAnalysis(url: URL, text: String, key: AnalysisKey, document: Document?) {
        // The same text against the same sources is already waiting or running: leave it alone,
        // so a refresh that changed nothing neither restarts the pass nor pushes the idle
        // deadline back. A different text, or new sources, supersedes it.
        if pendingKey[url] == key { return }
        pending[url]?.cancel()
        pendingKey[url] = key
        pending[url] = Task {
            try? await Task.sleep(for: idleDelay)
            guard !Task.isCancelled else { return }
            await runAnalysis(url: url, text: text, key: key, document: document)
        }
    }

    /// The tree for exactly `text`. The shared parse cache answers for documents that carry their
    /// text and declines file-backed ones whose snapshot is elided (the adapter's open-document
    /// list, every host-driven re-check); those are parsed from the full text here. Analysing an
    /// empty tree instead published "no findings" for the full text's key, and the editor's own
    /// request for the same text then read that empty result back.
    private func tree(for document: Document, text: String) async -> JavaSyntaxTree? {
        // The same materialized form the overlay parses, so both share one incremental tree.
        let materialized = document.contentSnapshot.isElided
            ? Document(
                id: document.id, url: document.url, displayName: document.displayName,
                contentSnapshot: TextSnapshot(version: document.version, text: text),
                selection: document.selection, cursor: document.cursor, viewport: document.viewport,
                languageIdentifier: document.languageIdentifier
            )
            : document
        if let cached = await parseCache.tree(for: materialized, edits: nil) { return cached }
        return JavaSyntaxParser().parse(text)
    }

    /// Test seam: awaited by every pass after it has read the sources version it is labelled
    /// with and before it reads the index, so a test can change the sources under a pass.
    nonisolated(unsafe) static var analysisStartHook: (@Sendable () async -> Void)?

    private func runAnalysis(url: URL, text: String, key requested: AnalysisKey, document: Document?) async {
        // Labelled with the sources it starts against. If they change while it runs, the label
        // is older than the index, so the next request sees it as stale and runs again.
        let key = AnalysisKey(
            textHash: requested.textHash, sourcesVersion: await index.sourcesVersion,
            overlayVersion: await index.overlayDeclarationsVersion, contextVersion: contextVersion
        )
        await Self.analysisStartHook?()
        let hash = key.textHash
        let resolution = scopes.context(for: url)
        let file = classifier.context(for: url)
        let profile = profile
        let enabled = profile.enabledRules(in: file)
        let thresholds = profile.thresholds
        let level = languageLevelResolver?(url)
        let stored = projectResults[url].flatMap { $0.hash == hash ? $0.inspections : nil } ?? []
        let (inspections, readiness) = await resolution.apply {
            let resolutionPending = await JavaResolutionReadiness(index: index)
            let tree: JavaSyntaxTree?
            if let document {
                tree = await self.tree(for: document, text: text)
            } else {
                tree = JavaSyntaxParser().parse(text)
            }
            guard let tree else { return (nil as [JavaInspection]?, resolutionPending) }
            let found = await JavaInspectionPipeline.inspect(
                text: text, url: url, tree: tree, index: index,
                enabled: enabled, thresholds: thresholds, projectFindings: stored, languageLevel: level
            )
            return (Optional(found), resolutionPending)
        }
        func release() {
            guard pendingKey[url] == requested else { return }
            pending[url] = nil
            pendingKey[url] = nil
        }
        // A cancelled pass never overwrites fresher results: publish nothing, but release
        // the pending registration so the next refresh schedules instead of joining a corpse.
        if Task.isCancelled {
            cancelledPasses += 1
            release()
            return
        }
        // Not even a parse: nothing was analysed, which is not "no problems". Publish nothing.
        guard let inspections else {
            release()
            return
        }
        completedPasses += 1
        // A pass reads the index in many hops (the readiness check, then one lookup per name), and
        // `setSources` can land between two of them: such a pass mixed two index states (the check
        // saw the JDK, a lookup did not). The same holds for a profile or scope change mid-pass.
        // Its findings describe no real state, so they are never published; if it was the newest
        // request, it is queued again against the state now in effect.
        let sourcesNow = await index.sourcesVersion
        let overlayNow = await index.overlayDeclarationsVersion
        if sourcesNow != key.sourcesVersion || overlayNow != key.overlayVersion || contextVersion != key.contextVersion {
            straddledPasses += 1
            release()
            if latestKey[url] == requested {
                let current = AnalysisKey(textHash: hash, sourcesVersion: sourcesNow, overlayVersion: overlayNow, contextVersion: contextVersion)
                latestKey[url] = current
                scheduleAnalysis(url: url, text: text, key: current, document: document)
            }
            return
        }
        // Passes overlap (the actor is re-entrant: a forced pass and a scheduled one, a pass that
        // started before the user typed or before new sources landed). Only the pass for the
        // newest key asked for publishes; one for an older text, older sources or another
        // classpath that finishes last is dropped, and the newer pass's result stands.
        if let latest = latestKey[url], latest != requested {
            release()
            return
        }
        // The same request, but the sources moved between the request and the pass's start: its
        // label is older than the cache's, so it must not replace a result already judged later.
        if let cached = cache[url], cached.textHash == hash, cached.key.sourcesVersion > key.sourcesVersion {
            release()
            return
        }
        let outcome = JavaInspectionPipeline.finalize(inspections, text: text, profile: profile, file: file)
        let diagnostics = outcome.visible.map { $0.asDiagnostic() }
        cache[url] = CachedResult(
            key: key, diagnostics: diagnostics, quiet: outcome.quiet.map { $0.asDiagnostic() },
            resolution: readiness
        )
        release()
        resultHandler?(url, diagnostics)
    }
}
