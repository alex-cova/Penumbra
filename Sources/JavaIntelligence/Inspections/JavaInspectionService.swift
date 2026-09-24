import EditorIntelligence
import Foundation

/// One static analysis warning surfaced in the Problems panel.
public struct JavaInspection: Sendable, Equatable {
    public enum Severity: Sendable {
        case warning
        case weakWarning
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

    func asDiagnostic() -> Diagnostic {
        Diagnostic(
            id: UUID(),
            severity: severity == .warning ? .warning : .hint,
            message: message,
            range: range,
            source: "java-inspection",
            code: id
        )
    }
}

public enum JavaInspectionRule: String, CaseIterable, Sendable {
    case unusedImport
    case duplicateImport
    case unresolvedImport
    case missingOverride
    case unresolvedType
    case classFileNameMismatch
}

/// Debounced static inspections for open Java files.
public actor JavaInspectionService: DiagnosticProvider {
    public nonisolated let name = "java-inspection"

    private let index: JavaIndex
    private let parseCache: JavaDocumentParseCache
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    private var enabledRules: Set<JavaInspectionRule>
    private let idleDelay: Duration
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
        enabledRules: Set<JavaInspectionRule> = Set(JavaInspectionRule.allCases),
        idleDelay: Duration = .milliseconds(800)
    ) {
        self.index = index
        self.parseCache = parseCache
        self.enabledRules = enabledRules
        self.idleDelay = idleDelay
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

    public func setEnabledRules(_ rules: Set<JavaInspectionRule>) {
        enabledRules = rules
        cache.removeAll()
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
            guard let tree, let context = JavaInspectionContext(source: text, tree: tree, url: url, index: index) else {
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
            return found
        }
        let diagnostics = inspections.map { $0.asDiagnostic() }
        cache[url] = CachedResult(textHash: hash, diagnostics: diagnostics)
        pending[url] = nil
        resultHandler?(url, diagnostics)
    }

    private func scope(for file: URL) -> Set<String>? {
        guard let classpathModel, let classpathPaths else { return nil }
        return classpathModel.visibleShardPaths(forFile: file, paths: classpathPaths)
    }
}
