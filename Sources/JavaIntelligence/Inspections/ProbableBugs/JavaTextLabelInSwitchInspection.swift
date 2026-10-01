import EditorIntelligence
import Foundation

/// `case 1: defalt: ...` — a label where a `case` or `default` was meant. A label that a `break`
/// or `continue` names is deliberate and stays quiet.
enum JavaTextLabelInSwitchInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.textLabelInSwitch
    static let nodeTypes: Set<String> = ["labeled_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.parent?.type == "switch_block_statement_group", node.namedChildCount >= 2,
              let label = node.namedChild(at: 0), label.type == "identifier", let body = node.namedChild(at: 1) else { return }
        var used = false
        body.forEachDescendant { descendant in
            guard descendant.type == "break_statement" || descendant.type == "continue_statement" else { return }
            if JavaJumpStatements.label(of: descendant)?.text == label.text { used = true }
        }
        guard !used else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Text label '\(label.text)' in 'switch' statement", node: label))
    }
}
