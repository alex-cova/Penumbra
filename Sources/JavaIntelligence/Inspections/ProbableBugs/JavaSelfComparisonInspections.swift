import EditorIntelligence
import Foundation

enum JavaSelfAssignmentInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.selfAssignment
    static let nodeTypes: Set<String> = ["assignment_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.operatorText == "=", let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right"),
              JavaSelfComparison.isSimpleReference(left), left.text == right.text else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Variable '\(left.text)' is assigned to itself", node: node,
            fixTitle: node.parent?.type == "expression_statement" ? "Remove assignment" : nil
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "assignment_expression", for: diagnostic, tree: tree, source: source),
              let statement = node.parent, statement.type == "expression_statement" else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: JavaSourceBytes.removalRange(of: statement), with: "", in: tree)
        return [CodeAction(title: "Remove assignment", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaSelfComparisonInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.expressionComparedToItself
    static let nodeTypes: Set<String> = ["binary_expression", "method_invocation"]
    private static let comparisons: Set<String> = ["==", "!=", "<", ">", "<=", ">="]
    private static let selfComparingMethods: Set<String> = ["equals", "equalsIgnoreCase", "compareTo"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        if node.type == "binary_expression" {
            guard let op = node.operatorText, comparisons.contains(op),
                  let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right"),
                  JavaSelfComparison.isSimpleReference(left), left.text == right.text else { return }
            // `x != x` is the NaN test, so a float or a type the file doesn't declare is left alone.
            guard let type = JavaDeclaredTypes.type(of: left), !type.isFloatingPoint, type.isPrimitiveNumber || type.isIntegral else { return }
            report(JavaInspectionSupport.inspection(rule, message: "'\(left.text)' is compared to itself", node: node))
            return
        }
        guard let name = node.child(byFieldName: "name")?.text, selfComparingMethods.contains(name),
              let object = node.child(byFieldName: "object"), JavaSelfComparison.isSimpleReference(object),
              let arguments = node.child(byFieldName: "arguments"), arguments.namedChildCount == 1,
              let argument = arguments.namedChild(at: 0), argument.text == object.text else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'\(object.text)' is compared to itself by '\(name)()'", node: node))
    }
}

enum JavaSelfComparison {
    /// `x`, `this.x` or `a.b.c`: no calls, so evaluating it twice gives the same value.
    static func isSimpleReference(_ node: SyntaxNode) -> Bool {
        switch node.type {
        case "identifier", "this": return true
        case "field_access":
            guard let object = node.child(byFieldName: "object") else { return false }
            return isSimpleReference(object)
        default: return false
        }
    }
}
