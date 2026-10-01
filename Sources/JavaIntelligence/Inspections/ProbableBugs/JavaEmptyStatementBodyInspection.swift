import EditorIntelligence
import Foundation

enum JavaEmptyStatementBodyInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.emptyStatementBody
    static let nodeTypes: Set<String> = ["if_statement", "while_statement", "for_statement", "enhanced_for_statement", "do_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        for body in emptyBodies(of: node) {
            let keyword = node.type.replacingOccurrences(of: "_statement", with: "").replacingOccurrences(of: "enhanced_", with: "")
            report(JavaInspectionSupport.inspection(
                rule, message: "'\(keyword)' statement has empty body", node: body, fixTitle: "Replace ';' with '{}'"
            ))
        }
    }

    /// The lone `;` bodies. A loop whose condition has side effects (`while (it.next());`) is a
    /// deliberate idiom and stays quiet; a `for` update such as `i++` is not a reason to.
    private static func emptyBodies(of node: SyntaxNode) -> [SyntaxNode] {
        let fields: [String]
        switch node.type {
        case "if_statement": fields = ["consequence", "alternative"]
        default: fields = ["body"]
        }
        let empties = fields.compactMap { node.child(byFieldName: $0) }.filter { $0.type == ";" }
        guard !empties.isEmpty else { return [] }
        if node.type != "if_statement", hasSideEffects(node) { return [] }
        return empties
    }

    private static func hasSideEffects(_ loop: SyntaxNode) -> Bool {
        let effectful: Set<String> = ["method_invocation", "assignment_expression", "update_expression", "object_creation_expression"]
        var found = false
        guard let condition = loop.child(byFieldName: "condition") else { return false }
        if effectful.contains(condition.type) { found = true }
        condition.forEachDescendant { if effectful.contains($0.type) { found = true } }
        return found
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let semicolon = JavaInspectionSupport.node(of: ";", for: diagnostic, tree: tree, source: source) else { return [] }
        let braces = JavaInspectionSupport.edit(replacingBytes: semicolon.byteRange, with: "{}", in: tree)
        let remove = JavaInspectionSupport.edit(replacingBytes: semicolon.byteRange, with: "", in: tree)
        return [
            CodeAction(title: "Replace ';' with '{}'", kind: "quickfix", edits: [braces], isPreferred: true),
            CodeAction(title: "Remove ';'", kind: "quickfix", edits: [remove]),
        ]
    }
}
