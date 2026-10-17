import EditorIntelligence
import Foundation
import LanguageSyntax
import TreeSitterJava

/// Tree-sitter syntax errors for Java, plus the composite that pairs them with `javac`.
///
/// `JavaInspectionContext` declines a broken tree, so without this a Java file gets no squiggle
/// until `javac` runs — and `javac` only runs once Umbra has configured it. The syntax provider
/// reuses the inspection pass's incremental tree, so there is no second parse.
enum JavaSyntaxDiagnostics {
    /// A `java-syntax` provider over the shared parse cache, with token names in javac's
    /// spelling (`identifier` → `<identifier>`).
    static func provider(cache: JavaDocumentParseCache) -> SyntaxDiagnosticProvider {
        SyntaxDiagnosticProvider(
            name: "java-syntax",
            languageIdentifiers: ["java"],
            severity: .error,
            tokenName: SyntaxProblem.javacTokenName,
            cache: cache,
            language: tree_sitter_java()
        )
    }
}

/// Drops the `javac` parser errors that restate a tree-sitter syntax problem, so one missing
/// `;` shows one squiggle and one Problems row instead of two. `javac`'s other errors
/// (say `cannot find symbol`) are kept, as are parser errors on lines without a syntax problem.
enum JavaParserErrorOverlap {
    /// The lines a syntax problem covers, by the start lines of its ranges.
    static func filter(javac: [Diagnostic], syntax: [Diagnostic]) -> [Diagnostic] {
        guard !syntax.isEmpty else { return javac }
        let lines = Set(syntax.map(\.range.start.line))
        return javac.filter { diagnostic in
            guard isParserError(diagnostic.message) else { return true }
            return !lines.contains(diagnostic.range.start.line)
        }
    }

    static func isParserError(_ message: String) -> Bool {
        if message.hasSuffix("expected") { return true }
        for prefix in [
            "illegal start of",
            "reached end of file while parsing",
            "not a statement",
            "unclosed",
            "'else' without 'if'",
            "orphaned",
        ] where message.hasPrefix(prefix) { return true }
        return false
    }
}

/// Drops the inspection findings that restate a fresh keyed `javac` error, so one typo shows
/// one squiggle and one Problems row instead of two. Only diagnostics with a `javac:<key>`
/// code (the warm server path) can suppress: cold CLI diagnostics carry no key, so meaning is
/// unknown and they suppress nothing. Stale compiler results suppress nothing either.
enum JavaDiagnosticsMerger {
    /// A `javac` key group per inspection rule; `nil` means the rule has no compiler twin.
    static func errorGroup(forInspection code: String?) -> String? {
        switch code {
        case "unresolved-member", "unresolved-type", "unresolved-import":
            return "compiler.err.cant.resolve"
        case "unreachable-code":
            return "compiler.err.unreachable.stmt"
        default:
            return nil
        }
    }

    static func filter(inspections: [Diagnostic], javac: [Diagnostic], fresh: Bool) -> [Diagnostic] {
        guard fresh else { return inspections }
        let keyed = javac.compactMap { diagnostic -> (line: Int, key: String)? in
            guard let code = diagnostic.code, code.hasPrefix("javac:") else { return nil }
            return (diagnostic.range.start.line, String(code.dropFirst("javac:".count)))
        }
        guard !keyed.isEmpty else { return inspections }
        return inspections.filter { finding in
            guard let group = errorGroup(forInspection: finding.code) else { return true }
            return !keyed.contains { $0.line == finding.range.start.line && $0.key.hasPrefix(group) }
        }
    }
}

/// The first diagnostics provider Java contributes: tree-sitter syntax errors, the `javac`
/// errors that say something new, and the inspection findings that say something newer still.
/// Built inside `JavaLanguageService`, which passes the inspection service in and lists no
/// separate inspections entry (one row per problem, not two).
public struct JavaSyntaxAwareDiagnostics: DiagnosticProvider {
    public nonisolated let name = "java-diagnostics"

    private let syntax: SyntaxDiagnosticProvider
    private let compiler: JavaCompilerDiagnosticsService
    private let inspections: JavaInspectionService?

    public init(
        syntax: SyntaxDiagnosticProvider,
        compiler: JavaCompilerDiagnosticsService,
        inspections: JavaInspectionService? = nil
    ) {
        self.syntax = syntax
        self.compiler = compiler
        self.inspections = inspections
    }

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        async let syntaxDiagnostics = syntax.diagnostics(for: document)
        async let compilerDiagnostics = compiler.diagnostics(for: document)
        guard let inspections else {
            let (syntaxResult, compilerResult) = await (syntaxDiagnostics, compilerDiagnostics)
            return syntaxResult + JavaParserErrorOverlap.filter(javac: compilerResult, syntax: syntaxResult)
        }
        async let inspectionDiagnostics = inspections.diagnostics(for: document)
        let (syntaxResult, compilerResult, inspectionResult) = await (
            syntaxDiagnostics, compilerDiagnostics, inspectionDiagnostics)
        let filteredCompiler = JavaParserErrorOverlap.filter(javac: compilerResult, syntax: syntaxResult)
        let fresh = await compiler.isFresh(document)
        return syntaxResult + filteredCompiler + JavaDiagnosticsMerger.filter(
            inspections: inspectionResult, javac: filteredCompiler, fresh: fresh)
    }

    /// Freshness the editor actually sees. The tiered provider unions per-provider stale
    /// sets, and this struct is Java's only diagnostics provider, so without this override
    /// the services' own overrides never fire and nothing is ever stale. The compiler only
    /// marks `javac` when it covers the file: an unconfigured compiler never lands a result,
    /// so its staleness would be a permanent lie.
    public func diagnosticsWithFreshness(for document: Document) async -> (diagnostics: [Diagnostic], staleSources: Set<String>) {
        let diagnostics = await diagnostics(for: document)
        var stale: Set<String> = []
        if await compiler.covers(document), await !compiler.isFresh(document) { stale.insert("javac") }
        if let inspections, await !inspections.isFresh(document) { stale.insert("java-inspection") }
        return (diagnostics, stale)
    }
}
