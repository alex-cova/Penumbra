import EditorIntelligence
import Foundation

/// `==` / `!=` between two values whose declared types make a reference comparison a mistake.
enum JavaIdentityComparison {
    /// `a == b` / `a != b` with its operands, when the operator is an equality test.
    static func operands(of node: SyntaxNode) -> (left: SyntaxNode, right: SyntaxNode, negated: Bool)? {
        guard let op = node.operatorText, op == "==" || op == "!=",
              let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right") else { return nil }
        return (left, right, op == "!=")
    }

    /// `left.equals(right)` or `!left.equals(right)`; the receiver is parenthesized unless it is atomic.
    static func equalsFix(title: String, for node: SyntaxNode, in tree: JavaSyntaxTree) -> [CodeAction] {
        guard let (left, right, negated) = operands(of: node) else { return [] }
        let atomic: Set<String> = ["identifier", "string_literal", "field_access", "method_invocation", "array_access", "this", "parenthesized_expression"]
        let receiver = atomic.contains(left.type) ? left.text : "(\(left.text))"
        let replacement = "\(negated ? "!" : "")\(receiver).equals(\(right.text))"
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: replacement, in: tree)
        return [CodeAction(title: title, kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaStringComparisonInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.stringComparisonIdentity
    static let nodeTypes: Set<String> = ["binary_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (left, right, _) = JavaIdentityComparison.operands(of: node),
              left.unparenthesized.type != "null_literal", right.unparenthesized.type != "null_literal",
              JavaDeclaredTypes.type(of: left) == .string, JavaDeclaredTypes.type(of: right) == .string else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "String values are compared using '\(node.operatorText ?? "==")', not 'equals()'", node: node, fixTitle: "Replace with 'equals()'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source) else { return [] }
        return JavaIdentityComparison.equalsFix(title: "Replace with 'equals()'", for: node, in: tree)
    }
}

enum JavaNumberComparisonInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.numberComparisonIdentity
    static let nodeTypes: Set<String> = ["binary_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (left, right, _) = JavaIdentityComparison.operands(of: node),
              let leftType = JavaDeclaredTypes.type(of: left), let rightType = JavaDeclaredTypes.type(of: right),
              leftType.isBoxedNumber, rightType.isBoxedNumber else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Number values are compared using '\(node.operatorText ?? "==")', not 'equals()'", node: node, fixTitle: "Replace with 'equals()'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source) else { return [] }
        return JavaIdentityComparison.equalsFix(title: "Replace with 'equals()'", for: node, in: tree)
    }
}

enum JavaArrayComparisonInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.arrayComparisonIdentity
    static let nodeTypes: Set<String> = ["binary_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (left, right, _) = JavaIdentityComparison.operands(of: node),
              JavaDeclaredTypes.type(of: left)?.isArray == true, JavaDeclaredTypes.type(of: right)?.isArray == true else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Arrays are compared using '\(node.operatorText ?? "==")', which compares references", node: node, fixTitle: "Replace with 'Arrays.equals()'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source),
              let (left, right, negated) = JavaIdentityComparison.operands(of: node) else { return [] }
        let replacement = "\(negated ? "!" : "")java.util.Arrays.equals(\(left.text), \(right.text))"
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: replacement, in: tree)
        return [CodeAction(title: "Replace with 'Arrays.equals()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
