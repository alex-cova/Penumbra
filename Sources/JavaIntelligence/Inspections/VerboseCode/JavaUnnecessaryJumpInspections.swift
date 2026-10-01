import EditorIntelligence
import Foundation

enum JavaJumpStatements {
    static let loops: Set<String> = ["for_statement", "enhanced_for_statement", "while_statement", "do_statement"]
    private static let comments: Set<String> = ["line_comment", "block_comment"]

    /// Whether nothing but comments follows `node` in its parent.
    static func isLastStatement(_ node: SyntaxNode) -> Bool {
        var next = node.nextNamedSibling
        while let sibling = next {
            if !comments.contains(sibling.type) { return false }
            next = sibling.nextNamedSibling
        }
        return true
    }

    /// The label of a `break` or `continue`, if it has one.
    static func label(of jump: SyntaxNode) -> SyntaxNode? { jump.firstNamedChild(ofType: "identifier") }

    static func removeFix(title: String, node: SyntaxNode, in tree: JavaSyntaxTree) -> [CodeAction] {
        let edit = JavaInspectionSupport.edit(replacingBytes: JavaSourceBytes.removalRange(of: node), with: "", in: tree)
        return [CodeAction(title: title, kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaUnnecessaryReturnInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unnecessaryReturn
    static let nodeTypes: Set<String> = ["return_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.namedChildCount == 0, let block = node.parent, JavaJumpStatements.isLastStatement(node), let owner = block.parent else { return }
        let endsVoidMethod = owner.type == "method_declaration" && owner.child(byFieldName: "type")?.type == "void_type"
            && owner.child(byFieldName: "body")?.byteRange == block.byteRange
        let endsConstructor = owner.type == "constructor_declaration" && block.type == "constructor_body"
        guard endsVoidMethod || endsConstructor else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'return' is unnecessary as the last statement", node: node, fixTitle: "Remove 'return'"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "return_statement", for: diagnostic, tree: tree, source: source) else { return [] }
        return JavaJumpStatements.removeFix(title: "Remove 'return'", node: node, in: tree)
    }
}

enum JavaUnnecessaryContinueInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unnecessaryContinue
    static let nodeTypes: Set<String> = ["continue_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard JavaJumpStatements.label(of: node) == nil, let block = node.parent, block.type == "block",
              JavaJumpStatements.isLastStatement(node), let loop = block.parent, JavaJumpStatements.loops.contains(loop.type),
              loop.child(byFieldName: "body")?.byteRange == block.byteRange else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'continue' is unnecessary as the last statement in a loop", node: node, fixTitle: "Remove 'continue'"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "continue_statement", for: diagnostic, tree: tree, source: source) else { return [] }
        return JavaJumpStatements.removeFix(title: "Remove 'continue'", node: node, in: tree)
    }
}

enum JavaUnnecessaryBreakInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unnecessaryBreak
    static let nodeTypes: Set<String> = ["break_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard JavaJumpStatements.label(of: node) == nil, let block = node.parent, block.type == "block",
              JavaJumpStatements.isLastStatement(node), block.parent?.type == "switch_rule" else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'break' is unnecessary at the end of a switch rule", node: node, fixTitle: "Remove 'break'"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "break_statement", for: diagnostic, tree: tree, source: source) else { return [] }
        return JavaJumpStatements.removeFix(title: "Remove 'break'", node: node, in: tree)
    }
}

/// Shared by the two "unnecessary label" rules: does the jump's innermost target already
/// belong to the labelled statement it names?
private func isLabelRedundant(_ jump: SyntaxNode, breakable: Set<String>) -> Bool {
    guard let label = JavaJumpStatements.label(of: jump)?.text else { return false }
    var current = jump.parent
    while let node = current {
        if breakable.contains(node.type) {
            guard let parent = node.parent, parent.type == "labeled_statement" else { return false }
            return parent.namedChild(at: 0)?.text == label
        }
        if ["lambda_expression", "method_declaration", "constructor_declaration", "class_body"].contains(node.type) { return false }
        current = node.parent
    }
    return false
}

enum JavaUnnecessaryLabelOnBreakInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unnecessaryLabelOnBreak
    static let nodeTypes: Set<String> = ["break_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard isLabelRedundant(node, breakable: JavaJumpStatements.loops.union(["switch_expression"])) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Unnecessary label '\(JavaJumpStatements.label(of: node)?.text ?? "")' on 'break'", node: node, fixTitle: "Remove label"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "break_statement", for: diagnostic, tree: tree, source: source) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: "break;", in: tree)
        return [CodeAction(title: "Remove label", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaUnnecessaryLabelOnContinueInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unnecessaryLabelOnContinue
    static let nodeTypes: Set<String> = ["continue_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard isLabelRedundant(node, breakable: JavaJumpStatements.loops) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Unnecessary label '\(JavaJumpStatements.label(of: node)?.text ?? "")' on 'continue'", node: node, fixTitle: "Remove label"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "continue_statement", for: diagnostic, tree: tree, source: source) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: "continue;", in: tree)
        return [CodeAction(title: "Remove label", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaUnusedLabelInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unusedLabel
    static let nodeTypes: Set<String> = ["labeled_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let label = node.namedChild(at: 0), label.type == "identifier", let body = node.namedChild(at: 1) else { return }
        var used = false
        body.forEachDescendant { descendant in
            guard descendant.type == "break_statement" || descendant.type == "continue_statement" else { return }
            if JavaJumpStatements.label(of: descendant)?.text == label.text { used = true }
        }
        guard !used else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Label '\(label.text)' is never used", node: label, fixTitle: "Remove label"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let label = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              let statement = label.parent, statement.type == "labeled_statement", let body = statement.namedChild(at: 1) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: statement.startByte..<body.startByte, with: "", in: tree)
        return [CodeAction(title: "Remove label", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
