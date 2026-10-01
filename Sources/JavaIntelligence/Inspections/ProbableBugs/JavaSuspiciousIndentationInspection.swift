import EditorIntelligence
import Foundation

/// `if (x)\n    a();\n    b();` — `b()` is indented like the body but is not part of it.
enum JavaSuspiciousIndentationInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.suspiciousIndentation
    static let nodeTypes: Set<String> = ["if_statement", "while_statement", "for_statement", "enhanced_for_statement"]
    private static let statementParents: Set<String> = ["block", "constructor_body", "switch_block_statement_group"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let parent = node.parent, statementParents.contains(parent.type), let next = node.nextNamedSibling,
              let body = lastBody(of: node), !["block", ";", "if_statement"].contains(body.type) else { return }
        let bytes = context.tree.sourceBytes
        guard JavaSourceBytes.hasLineBreak(between: node.endByte, and: next.startByte, in: bytes) else { return }
        let controlIndent = JavaSourceBytes.leadingWhitespace(ofLineContaining: node.startByte, in: bytes)
        let nextIndent = JavaSourceBytes.leadingWhitespace(ofLineContaining: next.startByte, in: bytes)
        guard nextIndent.count > controlIndent.count, nextIndent.hasPrefix(controlIndent) else { return }
        if JavaSourceBytes.hasLineBreak(between: node.startByte, and: body.startByte, in: bytes) {
            guard nextIndent == JavaSourceBytes.leadingWhitespace(ofLineContaining: body.startByte, in: bytes) else { return }
        }
        var end = next.startByte
        while end < next.endByte, bytes[end] != JavaSourceBytes.newline { end += 1 }
        report(JavaInspectionSupport.inspection(
            rule, message: "Statement is indented like the body of the control statement above, but is not part of it",
            startByte: next.startByte, endByte: end, tree: context.tree
        ))
    }

    private static func lastBody(of node: SyntaxNode) -> SyntaxNode? {
        node.type == "if_statement"
            ? (node.child(byFieldName: "alternative") ?? node.child(byFieldName: "consequence"))
            : node.child(byFieldName: "body")
    }
}
