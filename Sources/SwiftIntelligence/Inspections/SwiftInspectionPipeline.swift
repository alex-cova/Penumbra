import EditorIntelligence
import Foundation
import SwiftOperators
import SwiftSyntax

/// The one path from a file's text to its inspection findings. The editor's on-the-fly service and any
/// batch run go through it, so a rule behaves the same in both.
public enum SwiftInspectionPipeline {
    public struct Analysis: Sendable {
        /// Visible findings, after the options, syntax-error isolation and suppression, in source order.
        public var findings: [SwiftInspection]
        /// Maps the findings' byte ranges to editor positions.
        public var map: SourceTextMap
        /// The folded tree the findings were made from, for edits that need to know where a statement starts.
        var tree: SourceFileSyntax

        public static func empty(for text: String) -> Analysis {
            Analysis(findings: [], map: SourceTextMap(text), tree: SourceFileSyntax(statements: [], endOfFileToken: .endOfFileToken()))
        }
    }

    /// Parses `text` (through `cache`) and runs every rule `options` enables.
    ///
    /// Not for a keystroke: the parse is not incremental. The caller schedules it from a pause or a save and
    /// drops the answer if the text has moved on.
    public static func analyze(
        text: String, options: SwiftInspectionOptions, cache: SwiftSyntaxParseCache = .shared
    ) -> Analysis {
        guard let parsed = walk(text: text, options: options, cache: cache) else { return .empty(for: text) }
        return finish(parsed, options: options, extra: [])
    }

    /// The same, plus the index-backed rules (`unused-declaration`, and `unused-import` when the
    /// lookup knows module surfaces), which ask `lookup` about the rest of the project. For Inspect
    /// Code: it searches the project, so it is not for the editor's pass.
    public static func analyze(
        text: String, options: SwiftInspectionOptions, url: URL?, isTest: Bool = false,
        lookup: (any SwiftModuleSurfaceLookup)?, cache: SwiftSyntaxParseCache = .shared
    ) async -> Analysis {
        guard let parsed = walk(text: text, options: options, cache: cache) else { return .empty(for: text) }
        var extra: [SwiftInspection] = []
        if let lookup {
            if options.isEnabled(.unusedDeclaration) {
                extra += await SwiftProjectInspections.unusedDeclarations(
                    in: parsed.folded, text: text, url: url, isTest: isTest, treatsPublicApiAsUsed: options.treatsPublicApiAsUsed,
                    lookup: lookup
                )
            }
            if options.isEnabled(.unusedImport) {
                extra += await SwiftProjectInspections.unusedImports(
                    in: parsed.folded, text: text, url: url, lookup: lookup
                )
            }
        }
        return finish(parsed, options: options, extra: extra)
    }

    private struct Walked {
        let document: SwiftSyntaxDocument
        let folded: SourceFileSyntax
        let map: SourceTextMap
        let findings: [SwiftInspection]
    }

    private static func walk(text: String, options: SwiftInspectionOptions, cache: SwiftSyntaxParseCache) -> Walked? {
        let enabled = options.enabledRules
        guard !enabled.isEmpty else { return nil }
        let document = cache.document(for: text)
        let map = SourceTextMap(text)

        // Binary operators come out of the parser as flat sequences; precedence is applied here. A custom
        // operator the table does not know is left unfolded, and the error is ignored on purpose.
        let folded = OperatorTable.standardOperators.foldAll(document.tree, errorHandler: { _ in })
            .as(SourceFileSyntax.self) ?? document.tree

        let walker = SwiftInspectionWalker(enabled: enabled, limits: options.limits, utf8: map.utf8)
        walker.walk(folded)
        return Walked(document: document, folded: folded, map: map, findings: walker.findings)
    }

    private static func finish(_ walked: Walked, options: SwiftInspectionOptions, extra: [SwiftInspection]) -> Analysis {
        let folded = walked.folded
        let map = walked.map
        var findings = walked.findings + extra
        if walked.document.hasSyntaxErrors {
            // The parser recovers, and a rule reading half-written code would describe text that is not
            // there. What lies in a statement or declaration with an error in it is dropped.
            let broken = brokenRanges(in: folded)
            findings.removeAll { finding in broken.contains { $0.overlaps(finding.bytes) || $0.contains(finding.bytes.lowerBound) } }
        }
        findings = SwiftSuppression.filter(findings, tree: folded, map: map)
        findings = findings.map { finding in
            options.severities[finding.id].map(finding.withSeverity) ?? finding
        }
        findings.sort { ($0.bytes.lowerBound, $0.id) < ($1.bytes.lowerBound, $1.id) }
        return Analysis(findings: findings, map: map, tree: folded)
    }

    /// The edit that inserts `// umbra:disable <code>` above the statement or declaration around `finding`,
    /// or nil when there is no such line (the statement does not start its line) or one already carries a
    /// suppression comment, which would need merging.
    public static func suppressionFix(for finding: SwiftInspection, in analysis: Analysis) -> SwiftInspectionFix? {
        guard let token = analysis.tree.token(at: AbsolutePosition(utf8Offset: finding.bytes.lowerBound)) else { return nil }
        var node: Syntax? = Syntax(token)
        while let current = node, !(current.is(CodeBlockItemSyntax.self) || current.is(MemberBlockItemSyntax.self)) {
            node = current.parent
        }
        guard let item = node else { return nil }
        let utf8 = analysis.map.utf8
        let start = item.positionAfterSkippingLeadingTrivia.utf8Offset
        let lineStart = (utf8[..<start].lastIndex(of: UInt8(ascii: "\n")) ?? -1) + 1
        let indent = utf8[lineStart ..< start]
        guard indent.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }) else { return nil }
        let hasSuppression = item.leadingTrivia.contains { piece in
            if case .lineComment(let text) = piece { return text.contains("umbra:disable") }
            return false
        }
        guard !hasSuppression else { return nil }
        let comment = String(decoding: indent, as: UTF8.self) + "// umbra:disable \(finding.id)\n"
        return SwiftInspectionFix(
            title: "Suppress '\(finding.id)' for statement",
            edits: [.init(bytes: lineStart ..< lineStart, replacement: comment)]
        )
    }

    // MARK: - Syntax errors

    private static func brokenRanges(in tree: SourceFileSyntax) -> [Range<Int>] {
        let locator = ErrorLocator()
        locator.walk(tree)
        return locator.ranges
    }

    private final class ErrorLocator: SyntaxVisitor {
        var ranges: [Range<Int>] = []

        /// `.all`, not `.sourceAccurate`: that view leaves out missing nodes, which are what this looks for.
        init() { super.init(viewMode: .all) }

        override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
            if token.presence == .missing { record(Syntax(token)) }
            return .skipChildren
        }

        override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
            record(Syntax(node))
            return .skipChildren
        }

        /// The statement or member the error is in, and the function, initializer, accessor or closure around
        /// it. The structure the parser recovers to is not trustworthy past an unclosed `(` or `{`, which can
        /// pull the code after it into the broken construct, so the whole enclosing body goes, not only the line.
        private func record(_ node: Syntax) {
            var current: Syntax? = node
            var foundItem = false
            while let candidate = current {
                if !foundItem, candidate.is(CodeBlockItemSyntax.self) || candidate.is(MemberBlockItemSyntax.self) {
                    ranges.append(candidate.position.utf8Offset ..< candidate.endPosition.utf8Offset)
                    foundItem = true
                }
                if candidate.is(FunctionDeclSyntax.self) || candidate.is(InitializerDeclSyntax.self)
                    || candidate.is(AccessorDeclSyntax.self) || candidate.is(ClosureExprSyntax.self)
                    || candidate.is(DeinitializerDeclSyntax.self) {
                    ranges.append(candidate.position.utf8Offset ..< candidate.endPosition.utf8Offset)
                    return
                }
                current = candidate.parent
            }
            if !foundItem {
                ranges.append(node.position.utf8Offset ..< max(node.endPosition.utf8Offset, node.position.utf8Offset + 1))
            }
        }
    }
}
