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
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    private var profile: JavaInspectionProfile
    private var classifier = JavaInspectionFileClassifier()
    private var languageLevelResolver: (@Sendable (URL) -> Int?)?
    private let usageProvider: JavaFindUsagesProvider?
    /// Project-wide findings per file, valid for the text they were computed from.
    private var projectResults: [URL: (hash: Int, inspections: [JavaInspection])] = [:]
    private var idleDelay: Duration
    private var cache: [URL: CachedResult] = [:]
    private var pending: [URL: Task<Void, Never>] = [:]
    /// The text each pending task was scheduled for: a refresh for the same text skips
    /// scheduling whether the pass is still waiting or already running.
    private var pendingHash: [URL: Int] = [:]
    private var resultHandler: (@Sendable (URL, [Diagnostic]) -> Void)?

    private struct CachedResult {
        let textHash: Int
        let diagnostics: [Diagnostic]
        /// Findings set to "No highlighting (fix available)".
        let quiet: [Diagnostic]
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
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

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
        cache.removeAll()
    }

    public var currentProfile: JavaInspectionProfile { profile }

    /// Tells the Java language level of a file (its module's, else the JDK's), for the rules that
    /// suggest newer syntax. Without one they report nothing.
    public func setLanguageLevelResolver(_ resolver: (@Sendable (URL) -> Int?)?) {
        languageLevelResolver = resolver
        cache.removeAll()
    }

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
        guard let usageProvider, document.languageIdentifier == "java", let url = document.url else { return }
        let enabled = profile.enabledRules(in: classifier.context(for: url))
        guard !enabled.isDisjoint(with: JavaInspectionRegistry.projectRules) else { return }
        let text = JavaNavigationText.fullText(of: document)
        let hash = text.hashValue
        let scope = scope(for: url)
        let options = profile.projectOptions
        let found: [JavaInspection] = await JavaIndex.$queryScope.withValue(scope) {
            guard let tree = await parseCache.tree(for: document, edits: nil) else { return [] }
            return await JavaProjectInspector.inspect(
                source: text, url: url, tree: tree, provider: usageProvider, enabled: enabled, options: options
            )
        }
        guard !Task.isCancelled else { return }
        projectResults[url] = (hash, found)
        await analyzeNow(document, force: true)
    }

    public var documentParseCache: JavaDocumentParseCache { parseCache }

    public func setResultHandler(_ handler: (@Sendable (URL, [Diagnostic]) -> Void)?) {
        resultHandler = handler
    }

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        guard document.languageIdentifier == "java", let url = document.url else { return [] }
        let text = JavaNavigationText.fullText(of: document)
        let hash = text.hashValue
        if let cached = cache[url], cached.textHash == hash { return cached.diagnostics }
        scheduleAnalysis(url: url, text: text, hash: hash, document: document)
        return cache[url]?.diagnostics ?? []
    }

    /// Whether the cached result is for exactly this text. `document.text` is empty for
    /// elided file-backed documents, so this hashes the full text like the analysis does.
    public func isFresh(_ document: Document) -> Bool {
        guard document.languageIdentifier == "java", let url = document.url else { return false }
        return cache[url]?.textHash == JavaNavigationText.fullText(of: document).hashValue
    }

    public func diagnosticsWithFreshness(for document: Document) async -> (diagnostics: [Diagnostic], staleSources: Set<String>) {
        let diagnostics = await diagnostics(for: document)
        return (diagnostics, isFresh(document) ? [] : ["java-inspection"])
    }

    /// The findings of `url` set to "No highlighting (fix available)". They are not published as
    /// diagnostics; the code-action provider asks for them so their fixes stay on ⌥↩.
    public func quietFindings(for url: URL) -> [Diagnostic] {
        cache[url]?.quiet ?? []
    }

    public func analyzeNow(_ document: Document, force: Bool = false) async {
        guard document.languageIdentifier == "java", let url = document.url else { return }
        let text = JavaNavigationText.fullText(of: document)
        let hash = text.hashValue
        if !force, cache[url]?.textHash == hash { return }
        // A pass for this exact text is already waiting or running: joining it beats
        // cancelling and restarting it.
        if !force, pendingHash[url] == hash { return }
        pending[url]?.cancel()
        pendingHash[url] = nil
        await runAnalysis(url: url, text: text, hash: hash, document: document)
    }

    private func scheduleAnalysis(url: URL, text: String, hash: Int, document: Document?) {
        // The same text is already waiting or running: leave it alone, so a refresh that
        // changed nothing neither restarts the pass nor pushes the idle deadline back.
        // A different text supersedes it.
        if pendingHash[url] == hash { return }
        pending[url]?.cancel()
        pendingHash[url] = hash
        pending[url] = Task {
            try? await Task.sleep(for: idleDelay)
            guard !Task.isCancelled else { return }
            await runAnalysis(url: url, text: text, hash: hash, document: document)
        }
    }

    private func runAnalysis(url: URL, text: String, hash: Int, document: Document?) async {
        let scope = scope(for: url)
        let file = classifier.context(for: url)
        let profile = profile
        let enabled = profile.enabledRules(in: file)
        let thresholds = profile.thresholds
        let level = languageLevelResolver?(url)
        let stored = projectResults[url].flatMap { $0.hash == hash ? $0.inspections : nil } ?? []
        let inspections = await JavaIndex.$queryScope.withValue(scope) {
            let tree: JavaSyntaxTree?
            if let document {
                tree = await parseCache.tree(for: document, edits: nil)
            } else {
                tree = JavaSyntaxParser().parse(text)
            }
            guard let tree else { return [JavaInspection]() }
            return await JavaInspectionPipeline.inspect(
                text: text, url: url, tree: tree, index: index,
                enabled: enabled, thresholds: thresholds, projectFindings: stored, languageLevel: level
            )
        }
        // A cancelled pass never overwrites fresher results: publish nothing, but release
        // the pending registration so the next refresh schedules instead of joining a corpse.
        if Task.isCancelled {
            pending[url] = nil
            if pendingHash[url] == hash { pendingHash[url] = nil }
            return
        }
        let outcome = JavaInspectionPipeline.finalize(inspections, text: text, profile: profile, file: file)
        let diagnostics = outcome.visible.map { $0.asDiagnostic() }
        cache[url] = CachedResult(textHash: hash, diagnostics: diagnostics, quiet: outcome.quiet.map { $0.asDiagnostic() })
        pending[url] = nil
        if pendingHash[url] == hash { pendingHash[url] = nil }
        resultHandler?(url, diagnostics)
    }

    private func scope(for file: URL) -> Set<String>? {
        guard let classpathModel, let classpathPaths else { return nil }
        return classpathModel.visibleShardPaths(forFile: file, paths: classpathPaths)
    }
}
