import EditorIntelligence
import Foundation
import SwiftSyntax

/// What silences a finding.
///
/// - `// umbra:disable <code>[, <code>…]` (or `all`) in the comments directly above a statement or declaration
///   silences those rules anywhere inside it, the way `//noinspection` does for Java. The codes are the rule
///   ids (`force-try`).
/// - SwiftLint's comments are honoured for the rules that have a SwiftLint equivalent
///   (``SwiftInspectionRule/swiftLintName``): `// swiftlint:disable:next`, `:this`, `:previous`, and a
///   `disable` … `enable` region. A codebase that already carries them does not have to be annotated twice.
enum SwiftSuppression {
    static func filter(
        _ findings: [SwiftInspection], tree: SourceFileSyntax, map: SourceTextMap
    ) -> [SwiftInspection] {
        guard !findings.isEmpty else { return findings }
        let hasComments = map.source.contains("umbra:disable") || map.source.contains("swiftlint:")
        guard hasComments else { return findings }
        let directives = map.source.contains("swiftlint:") ? swiftLintDirectives(in: tree, map: map) : []
        return findings.filter { finding in
            !isSilencedByEnclosingComment(finding, tree: tree)
                && !isSilencedBySwiftLint(finding, directives: directives, map: map)
        }
    }

    // MARK: - umbra:disable

    private static func isSilencedByEnclosingComment(_ finding: SwiftInspection, tree: SourceFileSyntax) -> Bool {
        guard let token = tree.token(at: AbsolutePosition(utf8Offset: finding.bytes.lowerBound)) else { return false }
        var node: Syntax? = Syntax(token)
        while let current = node {
            if current.is(CodeBlockItemSyntax.self) || current.is(MemberBlockItemSyntax.self) || current.is(SwitchCaseSyntax.self),
               comments(in: current.leadingTrivia).contains(where: { names(in: $0, after: "umbra:disable").map { $0.contains(finding.id) || $0.contains("all") } ?? false }) {
                return true
            }
            node = current.parent
        }
        return false
    }

    /// The codes a comment names after `marker`, or nil if it does not carry the marker.
    static func names(in comment: String, after marker: String) -> Set<String>? {
        guard let range = comment.range(of: marker) else { return nil }
        var rest = comment[range.upperBound...]
        // `umbra:disable:next` style suffixes are not used; a `:` here would start a different marker.
        if rest.first == ":" { return nil }
        rest = rest.drop { $0 == " " }
        let words = rest.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "*" || $0 == "/" })
        return Set(words.map(String.init))
    }

    private static func comments(in trivia: Trivia) -> [String] {
        trivia.compactMap { piece in
            switch piece {
            case .lineComment(let text), .blockComment(let text), .docLineComment(let text), .docBlockComment(let text): text
            default: nil
            }
        }
    }

    // MARK: - swiftlint:disable

    private struct Directive {
        enum Kind { case next, this, previous, disable, enable }
        var line: Int
        var kind: Kind
        var names: Set<String>
    }

    private static func swiftLintDirectives(in tree: SourceFileSyntax, map: SourceTextMap) -> [Directive] {
        var directives: [Directive] = []
        for token in tree.tokens(viewMode: .sourceAccurate) {
            var offset = token.position.utf8Offset
            for piece in token.leadingTrivia {
                collect(piece, at: offset, map: map, into: &directives)
                offset += piece.sourceLength.utf8Length
            }
            offset = token.endPositionBeforeTrailingTrivia.utf8Offset
            for piece in token.trailingTrivia {
                collect(piece, at: offset, map: map, into: &directives)
                offset += piece.sourceLength.utf8Length
            }
        }
        return directives.sorted { $0.line < $1.line }
    }

    private static func collect(_ piece: TriviaPiece, at offset: Int, map: SourceTextMap, into directives: inout [Directive]) {
        let text: String
        switch piece {
        case .lineComment(let value), .blockComment(let value): text = value
        default: return
        }
        guard let range = text.range(of: "swiftlint:") else { return }
        let words = text[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" || $0 == "*" || $0 == "/" })
        guard let command = words.first else { return }
        let kind: Directive.Kind
        switch command {
        case "disable": kind = .disable
        case "enable": kind = .enable
        case "disable:next": kind = .next
        case "disable:this": kind = .this
        case "disable:previous": kind = .previous
        default: return
        }
        directives.append(Directive(line: map.position(atByte: offset).line, kind: kind, names: Set(words.dropFirst().map(String.init))))
    }

    private static func isSilencedBySwiftLint(_ finding: SwiftInspection, directives: [Directive], map: SourceTextMap) -> Bool {
        guard !directives.isEmpty, let rule = SwiftInspectionRule(code: finding.id), let name = rule.swiftLintName else { return false }
        let line = map.position(atByte: finding.bytes.lowerBound).line
        func covers(_ names: Set<String>) -> Bool { names.contains(name) || names.contains("all") }
        var regionOpen = false
        for directive in directives where directive.line <= line + 1 {
            guard covers(directive.names) else { continue }
            switch directive.kind {
            case .next where directive.line == line - 1: return true
            case .this where directive.line == line: return true
            case .previous where directive.line == line + 1: return true
            case .disable where directive.line <= line: regionOpen = true
            case .enable where directive.line <= line: regionOpen = false
            default: break
            }
        }
        return regionOpen
    }
}
