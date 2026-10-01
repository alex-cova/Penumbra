import EditorIntelligence
import Foundation

/// How "Suppress" quick fixes silence a warning (IntelliJ's "Suppress with 'noinspection'
/// comment instead of annotation").
public enum JavaSuppressionStyle: String, Sendable, CaseIterable {
    /// `@SuppressWarnings("code")` on the enclosing member or class.
    case annotation
    /// A `//noinspection code` comment above the enclosing statement or declaration.
    case comment
}

/// `@SuppressWarnings` and `//noinspection` support: which warnings a file silences, and the
/// quick fixes that add the silencing.
enum JavaSuppression {
    /// Declarations that can carry `@SuppressWarnings` in their `modifiers`.
    private static let annotatable: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration",
        "annotation_type_declaration", "method_declaration", "constructor_declaration",
        "field_declaration", "local_variable_declaration",
    ]
    /// Nodes a `//noinspection` comment on the line above applies to.
    private static let commentable: Set<String> = annotatable.union([
        "import_declaration", "expression_statement", "return_statement", "if_statement", "for_statement",
        "enhanced_for_statement", "while_statement", "do_statement", "try_statement", "switch_expression",
        "throw_statement", "assert_statement", "yield_statement", "synchronized_statement",
    ])

    // MARK: - Is a warning suppressed

    /// Whether the warning `code` at `byteOffset` is silenced by an enclosing `@SuppressWarnings`
    /// (naming `code`, or `"all"`) or by a `//noinspection` comment above an enclosing statement.
    static func isSuppressed(code: String, atByteOffset byteOffset: Int, tree: JavaSyntaxTree) -> Bool {
        var node: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        while let current = node {
            if annotatable.contains(current.type), let annotation = suppressAnnotation(in: current) {
                let codes = suppressedCodes(in: annotation)
                if codes.contains(code) || codes.contains("all") { return true }
            }
            if commentable.contains(current.type),
               let codes = noinspectionCodes(aboveLineContaining: current.startByte, in: tree.sourceBytes),
               codes.contains(code) || codes.contains("ALL") {
                return true
            }
            node = current.parent
        }
        return false
    }

    static func suppressAnnotation(in declaration: SyntaxNode) -> SyntaxNode? {
        guard let modifiers = declaration.firstNamedChild(ofType: "modifiers") else { return nil }
        return modifiers.namedChildren(ofType: "annotation").first { annotation in
            annotation.child(byFieldName: "name")?.text.hasSuffix("SuppressWarnings") == true
        }
    }

    /// The string literals of a `@SuppressWarnings(...)` annotation.
    static func suppressedCodes(in annotation: SyntaxNode) -> [String] {
        let text = annotation.text
        guard let open = text.firstIndex(of: "(") else { return [] }
        var codes: [String] = []
        var current: String?
        for character in text[open...] {
            if character == "\"" {
                if let literal = current {
                    codes.append(literal)
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(character)
            }
        }
        return codes
    }

    /// The codes of a `//noinspection a, b` comment on the line above the one holding `byteOffset`.
    static func noinspectionCodes(aboveLineContaining byteOffset: Int, in bytes: [UInt8]) -> [String]? {
        let lineStart = lineStart(containing: byteOffset, in: bytes)
        guard lineStart > 0 else { return nil }
        let previousStart = Self.lineStart(containing: lineStart - 1, in: bytes)
        return noinspectionCodes(inLine: previousStart..<(lineStart - 1), bytes: bytes)
    }

    private static func noinspectionCodes(inLine range: Range<Int>, bytes: [UInt8]) -> [String]? {
        let line = String(decoding: bytes[range], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let marker = "//noinspection"
        guard line.hasPrefix(marker) else { return nil }
        return line.dropFirst(marker.count)
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map(String.init)
    }

    private static func lineStart(containing offset: Int, in bytes: [UInt8]) -> Int {
        var index = min(max(0, offset), bytes.count)
        while index > 0, bytes[index - 1] != 10 { index -= 1 }
        return index
    }

    private static func lineEnd(containing offset: Int, in bytes: [UInt8]) -> Int {
        var index = min(max(0, offset), bytes.count)
        while index < bytes.count, bytes[index] != 10 { index += 1 }
        return index
    }

    // MARK: - Quick fixes

    /// "Suppress" fixes for the warning `code` found at `byteOffset`.
    static func fixes(
        code: String, atByteOffset byteOffset: Int, tree: JavaSyntaxTree, source: String, style: JavaSuppressionStyle
    ) -> [CodeAction] {
        var chain: [SyntaxNode] = []
        var node: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        while let current = node {
            chain.append(current)
            node = current.parent
        }
        if style == .annotation {
            // The innermost three: a method deep in nested classes would otherwise list them all.
            let fixes = chain.lazy.compactMap { annotationFix(code: code, declaration: $0, tree: tree, source: source) }.prefix(3)
            // An import has no declaration to annotate, so it falls back to the comment.
            if !fixes.isEmpty { return Array(fixes) }
        }
        guard let target = chain.first(where: { commentable.contains($0.type) }),
              let fix = commentFix(code: code, target: target, tree: tree, source: source) else { return [] }
        return [fix]
    }

    private static func annotationFix(code: String, declaration: SyntaxNode, tree: JavaSyntaxTree, source: String) -> CodeAction? {
        guard annotatable.contains(declaration.type) else { return nil }
        let bytes = tree.sourceBytes
        let title = "Suppress '\(code)' for \(describe(declaration))"
        if let existing = suppressAnnotation(in: declaration) {
            let codes = suppressedCodes(in: existing)
            guard !codes.contains(code) else { return nil }
            let merged = codes + [code]
            let list = merged.count == 1 ? "\"\(merged[0])\"" : "{" + merged.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
            let edit = TextEdit(range: JavaNavigationText.textRange(for: existing.byteRange, in: source), replacement: "@SuppressWarnings(\(list))")
            return CodeAction(title: title, kind: "quickfix", edits: [edit])
        }
        let start = declaration.startByte
        let lineStart = lineStart(containing: start, in: bytes)
        let indentBytes = bytes[lineStart..<start]
        let startsOwnLine = indentBytes.allSatisfy { $0 == 32 || $0 == 9 }
        let separator = declaration.type == "local_variable_declaration" || !startsOwnLine
            ? " " : "\n" + String(decoding: indentBytes, as: UTF8.self)
        let edit = TextEdit(range: JavaNavigationText.textRange(for: start..<start, in: source),
                            replacement: "@SuppressWarnings(\"\(code)\")\(separator)")
        return CodeAction(title: title, kind: "quickfix", edits: [edit])
    }

    private static func commentFix(code: String, target: SyntaxNode, tree: JavaSyntaxTree, source: String) -> CodeAction? {
        let bytes = tree.sourceBytes
        let start = target.startByte
        let lineStart = lineStart(containing: start, in: bytes)
        let title = "Suppress '\(code)' for statement with //noinspection"
        if lineStart > 0 {
            let previousStart = Self.lineStart(containing: lineStart - 1, in: bytes)
            let previousEnd = lineStart - 1
            if let existing = noinspectionCodes(inLine: previousStart..<previousEnd, bytes: bytes) {
                guard !existing.contains(code) else { return nil }
                let end = lineEnd(containing: previousStart, in: bytes)
                let edit = TextEdit(range: JavaNavigationText.textRange(for: end..<end, in: source), replacement: ", \(code)")
                return CodeAction(title: title, kind: "quickfix", edits: [edit])
            }
        }
        let indent = String(decoding: bytes[lineStart..<start].prefix { $0 == 32 || $0 == 9 }, as: UTF8.self)
        let edit = TextEdit(range: JavaNavigationText.textRange(for: lineStart..<lineStart, in: source),
                            replacement: "\(indent)//noinspection \(code)\n")
        return CodeAction(title: title, kind: "quickfix", edits: [edit])
    }

    private static func describe(_ declaration: SyntaxNode) -> String {
        let kind: String
        switch declaration.type {
        case "method_declaration": kind = "method"
        case "constructor_declaration": kind = "constructor"
        case "field_declaration": kind = "field"
        case "local_variable_declaration": kind = "variable"
        case "interface_declaration": kind = "interface"
        case "enum_declaration": kind = "enum"
        case "record_declaration": kind = "record"
        default: kind = "class"
        }
        if let name = declaration.child(byFieldName: "name")?.text {
            return "\(kind) '\(name)'"
        }
        return kind
    }
}
