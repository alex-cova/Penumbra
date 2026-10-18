import EditorIntelligence
import Foundation

struct JavaIntentionOffer {
    var intention: JavaIntention
    var title: String
    var edits: [TextEdit]
    var preview: String
}

/// Finds the intentions that apply at a caret and turns them into code actions.
enum JavaIntentionEngine {
    static func actions(
        tree: JavaSyntaxTree,
        source: String,
        utf16Offset: Int,
        options: JavaIntentionOptions,
        index: JavaIndex,
        fileURL: URL?
    ) async -> [CodeAction] {
        let chain = ancestors(at: utf16Offset, in: source, tree: tree)
        let inComment = chain.first.map { $0.type == "line_comment" || $0.type == "block_comment" } ?? false
        var offers: [JavaIntentionOffer] = []
        var seen = Set<String>()
        for node in chain {
            let found = inComment
                ? JavaCommentIntentions.offers(for: node, options: options, source: source)
                : JavaIntentionTransforms.offers(for: node, options: options, source: source)
            for offer in found where seen.insert(key(of: offer)).inserted {
                offers.append(offer)
            }
        }
        if !inComment {
            for node in chain where node.type == "local_variable_declaration" {
                if let offer = await JavaTypeIntentions.varToExplicit(
                    for: node, options: options, source: source, index: index, fileURL: fileURL
                ), seen.insert(key(of: offer)).inserted {
                    offers.append(offer)
                }
            }
        }
        return offers.map { offer in
            CodeAction(
                title: offer.title,
                kind: offer.intention.kind,
                edits: offer.edits,
                preview: options.showsPreview ? offer.preview : nil,
                options: [
                    CodeActionOption(
                        title: "Disable '\(offer.intention.title)'",
                        command: CodeActionCommand(id: JavaIntentionCommand.disable, arguments: [offer.intention.id])
                    ),
                    CodeActionOption(
                        title: "Edit intention settings…",
                        command: CodeActionCommand(id: JavaIntentionCommand.configure, arguments: [offer.intention.id])
                    ),
                ]
            )
        }
    }

    /// Red when the caret line has a compiler or inspection diagnostic (those have fixes). Yellow
    /// when an enabled intention applies. The type of a `var` is not computed here.
    static func bulb(
        tree: JavaSyntaxTree?,
        source: String,
        utf16Offset: Int,
        options: JavaIntentionOptions,
        diagnostics: [Diagnostic]
    ) -> CodeActionBulb {
        guard options.showsBulb else { return .none }
        if hasQuickFix(at: utf16Offset, in: source, diagnostics: diagnostics) { return .quickFix }
        guard let tree else { return .none }
        let chain = ancestors(at: utf16Offset, in: source, tree: tree)
        let inComment = chain.first.map { $0.type == "line_comment" || $0.type == "block_comment" } ?? false
        for node in chain {
            if inComment {
                if !JavaCommentIntentions.offers(for: node, options: options, source: source).isEmpty { return .intention }
            } else if !JavaIntentionTransforms.offers(for: node, options: options, source: source).isEmpty
                        || JavaTypeIntentions.noticesVar(for: node, options: options) {
                return .intention
            }
        }
        return .none
    }

    static func hasQuickFix(at utf16Offset: Int, in source: String, diagnostics: [Diagnostic]) -> Bool {
        let ns = source as NSString
        guard ns.length > 0 else { return false }
        let caret = min(max(0, utf16Offset), ns.length)
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        return diagnostics.contains { diagnostic in
            guard diagnostic.source == "javac" || diagnostic.source == "java-inspection" else { return false }
            let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
            guard range.location <= ns.length else { return false }
            let diagnosticLine = ns.lineRange(for: NSRange(location: min(range.location, ns.length), length: 0))
            return NSIntersectionRange(diagnosticLine, line).length > 0
        }
    }

    private static func key(of offer: JavaIntentionOffer) -> String {
        let start = offer.edits.first?.range.start.utf16Offset ?? 0
        return "\(offer.intention.id):\(start)"
    }

    /// The node at the caret, then each parent. A caret sitting just after a token uses that token.
    static func ancestors(at utf16Offset: Int, in source: String, tree: JavaSyntaxTree) -> [SyntaxNode] {
        let ns = source as NSString
        let utf16 = min(max(0, utf16Offset), ns.length)
        var byte = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16, in: source)
        byte = min(max(0, byte), tree.sourceBytes.count)
        let lookup = byte == tree.sourceBytes.count ? max(0, byte - 1) : byte
        var node = tree.node(atByteOffset: lookup)
        // A caret in the gap after a token still belongs to that token. A caret on the first
        // byte of a token belongs to that token, so it is not stepped back off of.
        if byte > 0, node.startByte > byte {
            node = tree.node(atByteOffset: byte - 1)
        }
        var chain: [SyntaxNode] = []
        var current: SyntaxNode? = node
        while let item = current {
            chain.append(item)
            current = item.parent
        }
        return chain
    }
}

enum JavaIntentionEdit {
    static func replacing(_ range: Range<Int>, with text: String, in tree: JavaSyntaxTree) -> TextEdit {
        JavaInspectionSupport.edit(replacingBytes: range, with: text, in: tree)
    }

    static func offer(
        _ intention: JavaIntention, title: String? = nil, replacing range: Range<Int>, with text: String,
        in tree: JavaSyntaxTree, source: String
    ) -> JavaIntentionOffer? {
        guard !text.isEmpty else { return nil }
        let original = tree.text(in: range)
        guard original != text else { return nil }
        let edit = replacing(range, with: text, in: tree)
        return JavaIntentionOffer(
            intention: intention, title: title ?? intention.title, edits: [edit],
            preview: JavaIntentionPreview.make(applying: [edit], to: source)
        )
    }

    static func offer(
        _ intention: JavaIntention, title: String? = nil, edits: [TextEdit], source: String
    ) -> JavaIntentionOffer? {
        guard !edits.isEmpty else { return nil }
        return JavaIntentionOffer(
            intention: intention, title: title ?? intention.title, edits: edits,
            preview: JavaIntentionPreview.make(applying: edits, to: source)
        )
    }
}

enum JavaIntentionPreview {
    /// The lines the edits rewrite, taken from the text after they are applied. At most eight.
    static func make(applying edits: [TextEdit], to source: String) -> String {
        guard let start = edits.map({ $0.range.start.utf16Offset }).min(),
              let end = edits.map({ $0.range.end.utf16Offset }).max() else { return "" }
        let ns = source as NSString
        guard start >= 0, start <= ns.length, end >= start, end <= ns.length else {
            return edits.first?.replacement ?? ""
        }
        let startLine = ns.lineRange(for: NSRange(location: start, length: 0)).location
        let lineIndex = startLine == 0 ? 0 : ns.substring(with: NSRange(location: 0, length: startLine))
            .components(separatedBy: "\n").count - 1
        var result = ns
        for edit in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let location = edit.range.start.utf16Offset
            let length = edit.range.end.utf16Offset - location
            guard location >= 0, length >= 0, location + length <= result.length else { return edit.replacement }
            result = result.replacingCharacters(in: NSRange(location: location, length: length), with: edit.replacement) as NSString
        }
        let lines = (result as String).components(separatedBy: "\n")
        let originalSpan = ns.substring(with: NSRange(location: start, length: end - start))
            .components(separatedBy: "\n").count
        let inserted = edits.reduce(0) { $0 + max(0, $1.replacement.components(separatedBy: "\n").count - 1) }
        let count = min(8, max(1, originalSpan + inserted))
        guard lineIndex >= 0, lineIndex < lines.count else { return "" }
        return lines.dropFirst(lineIndex).prefix(count).joined(separator: "\n")
    }
}

enum JavaIntentionSyntax {
    static func indent(of node: SyntaxNode) -> String {
        JavaSourceBytes.leadingWhitespace(ofLineContaining: node.startByte, in: node.tree.sourceBytes)
    }

    static func indentLines(_ text: String, by pad: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.isEmpty ? "" : pad + line
        }.joined(separator: "\n")
    }

    static func hasComment(_ node: SyntaxNode) -> Bool {
        node.children.contains { $0.type == "line_comment" || $0.type == "block_comment" }
    }

    /// An operand of `&&` that needs parentheses so it stays one operand.
    static func andOperand(_ node: SyntaxNode) -> String {
        let inner = node.unparenthesized
        if inner.type == "binary_expression", inner.operatorText == "||" { return "(\(inner.text))" }
        if inner.type == "ternary_expression" || inner.type == "assignment_expression" { return "(\(inner.text))" }
        return inner.text
    }

    static func singleStatement(in block: SyntaxNode) -> SyntaxNode? {
        guard block.type == "block", !hasComment(block) else { return nil }
        let statements = block.namedChildren.filter { $0.type != "line_comment" && $0.type != "block_comment" }
        guard statements.count == 1, let only = statements.first, only.type != "local_variable_declaration" else { return nil }
        return only
    }
}
