import EditorIntelligence
import Foundation

/// One static analysis warning surfaced in the Problems panel.
public struct JavaInspection: Sendable, Equatable {
    public enum Severity: String, Sendable, CaseIterable {
        case error
        case warning
        case weakWarning
        case info
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

    func asDiagnostic() -> Diagnostic {
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
    private var enabledRules: Set<JavaInspectionRule>
    private var severityOverrides: [JavaInspectionRule: JavaInspection.Severity] = [:]
    private var thresholds = JavaInspectionThresholds.standard
    private var projectOptions = JavaProjectInspectionOptions.standard
    private let usageProvider: JavaFindUsagesProvider?
    /// Project-wide findings per file, valid for the text they were computed from.
    private var projectResults: [URL: (hash: Int, inspections: [JavaInspection])] = [:]
    private var idleDelay: Duration
    private var cache: [URL: CachedResult] = [:]
    private var pending: [URL: Task<Void, Never>] = [:]
    private var resultHandler: (@Sendable (URL, [Diagnostic]) -> Void)?

    private struct CachedResult {
        let textHash: Int
        let diagnostics: [Diagnostic]
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
        self.enabledRules = enabledRules
        self.idleDelay = idleDelay
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

    /// How long the file must rest before it is analyzed again (IntelliJ's "Autoreparse delay").
    public func setIdleDelay(_ delay: Duration) { idleDelay = delay }

    public func setEnabledRules(_ rules: Set<JavaInspectionRule>) {
        enabledRules = rules
        cache.removeAll()
    }

    /// Severity per rule where the user changed it from the rule's default.
    public func setSeverityOverrides(_ overrides: [JavaInspectionRule: JavaInspection.Severity]) {
        severityOverrides = overrides
        cache.removeAll()
    }

    /// The numbers behind the metric rules (complexity, nesting, parameter count, lengths).
    public func setThresholds(_ thresholds: JavaInspectionThresholds) {
        guard thresholds != self.thresholds else { return }
        self.thresholds = thresholds
        cache.removeAll()
    }

    public func setProjectOptions(_ options: JavaProjectInspectionOptions) {
        guard options != projectOptions else { return }
        projectOptions = options
        projectResults.removeAll()
        cache.removeAll()
    }

    /// Runs the rules that need usages from the whole project (unused declarations, access that
    /// can be weaker, return values nobody reads, parameters that never vary) for one file and
    /// folds their findings into the file's diagnostics. Meant for a save or an index change: one
    /// usage search per declaration. The findings are dropped as soon as the text changes.
    public func runProjectInspections(for document: Document) async {
        guard let usageProvider, document.languageIdentifier == "java", let url = document.url,
              !enabledRules.isDisjoint(with: JavaInspectionRegistry.projectRules) else { return }
        let text = JavaNavigationText.fullText(of: document)
        let hash = text.hashValue
        let scope = scope(for: url)
        let found: [JavaInspection] = await JavaIndex.$queryScope.withValue(scope) {
            guard let tree = await parseCache.tree(for: document, edits: nil) else { return [] }
            return await JavaProjectInspector.inspect(
                source: text, url: url, tree: tree, provider: usageProvider, enabled: enabledRules, options: projectOptions
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

    public func analyzeNow(_ document: Document, force: Bool = false) async {
        guard document.languageIdentifier == "java", let url = document.url else { return }
        let text = JavaNavigationText.fullText(of: document)
        let hash = text.hashValue
        if !force, cache[url]?.textHash == hash { return }
        pending[url]?.cancel()
        await runAnalysis(url: url, text: text, hash: hash, document: document)
    }

    private func scheduleAnalysis(url: URL, text: String, hash: Int, document: Document?) {
        pending[url]?.cancel()
        pending[url] = Task {
            try? await Task.sleep(for: idleDelay)
            guard !Task.isCancelled else { return }
            await runAnalysis(url: url, text: text, hash: hash, document: document)
        }
    }

    private func runAnalysis(url: URL, text: String, hash: Int, document: Document?) async {
        let scope = scope(for: url)
        let inspections = await JavaIndex.$queryScope.withValue(scope) {
            let tree: JavaSyntaxTree?
            if let document {
                tree = await parseCache.tree(for: document, edits: nil)
            } else {
                tree = JavaSyntaxParser().parse(text)
            }
            guard let tree, let context = JavaInspectionContext(source: text, tree: tree, url: url, index: index, thresholds: thresholds) else {
                return [JavaInspection]()
            }
            var found: [JavaInspection] = []
            if enabledRules.contains(.unusedImport) {
                found.append(contentsOf: JavaUnusedImportInspection.inspect(source: text, tree: tree))
            }
            if enabledRules.contains(.duplicateImport) {
                found.append(contentsOf: JavaDuplicateImportInspection.inspect(source: text, tree: tree))
            }
            if enabledRules.contains(.unresolvedImport) {
                found.append(contentsOf: await JavaUnresolvedImportInspection.inspect(context: context, index: index))
            }
            if enabledRules.contains(.missingOverride) {
                found.append(contentsOf: await JavaMissingOverrideInspection.inspect(source: text, url: url, index: index, tree: tree))
            }
            if enabledRules.contains(.unresolvedType) {
                found.append(contentsOf: await JavaUnresolvedTypeInspection.inspect(source: text, url: url, index: index, walker: context.walker))
            }
            if enabledRules.contains(.classFileNameMismatch) {
                found.append(contentsOf: JavaClassFileNameInspection.inspect(context: context))
            }
            found.append(contentsOf: JavaInspectionRunner.run(context: context, enabled: enabledRules))
            found.append(contentsOf: JavaInspectionRunner.runFlow(context: context, enabled: enabledRules))
            if let stored = projectResults[url], stored.hash == hash {
                found.append(contentsOf: stored.inspections.filter { inspection in
                    JavaInspectionRule(code: inspection.id).map(enabledRules.contains) == true
                })
            }
            found.append(contentsOf: await JavaInspectionRunner.runTyped(context: context, enabled: enabledRules))
            return found
        }
        let diagnostics = applySeverityOverrides(suppressionFiltered(inspections, text: text)).map { $0.asDiagnostic() }
        cache[url] = CachedResult(textHash: hash, diagnostics: diagnostics)
        pending[url] = nil
        resultHandler?(url, diagnostics)
    }

    private func applySeverityOverrides(_ inspections: [JavaInspection]) -> [JavaInspection] {
        guard !severityOverrides.isEmpty else { return inspections }
        return inspections.map { inspection in
            guard let rule = JavaInspectionRule(code: inspection.id), let severity = severityOverrides[rule] else { return inspection }
            return inspection.withSeverity(severity)
        }
    }

    /// Drops what an `@SuppressWarnings` or `//noinspection` in the file silences.
    private func suppressionFiltered(_ inspections: [JavaInspection], text: String) -> [JavaInspection] {
        guard !inspections.isEmpty, text.contains("SuppressWarnings") || text.contains("noinspection"),
              let tree = JavaSyntaxParser().parse(text) else { return inspections }
        let ns = text as NSString
        return inspections.filter { inspection in
            let location = min(max(0, inspection.range.start.utf16Offset), ns.length)
            let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: location, in: text)
            return !JavaSuppression.isSuppressed(code: inspection.id, atByteOffset: byteOffset, tree: tree)
        }
    }

    private func scope(for file: URL) -> Set<String>? {
        guard let classpathModel, let classpathPaths else { return nil }
        return classpathModel.visibleShardPaths(forFile: file, paths: classpathPaths)
    }
}
