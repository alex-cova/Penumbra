import EditorIntelligence
import Foundation

enum JavaSynchronizationOnStringLiteralInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.synchronizationOnStringLiteral
    static let nodeTypes: Set<String> = ["synchronized_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let lock = node.namedChild(at: 0)?.unparenthesized, lock.type == "string_literal" else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Synchronization on the String literal \(lock.text): interned strings are shared", node: lock))
    }
}

enum JavaSynchronizationOnThisInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.synchronizationOnThis
    static let nodeTypes: Set<String> = ["synchronized_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let lock = node.namedChild(at: 0)?.unparenthesized, lock.type == "this" else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Synchronization on 'this': any caller can take the same lock; use a private lock object", node: lock))
    }
}

enum JavaWaitNotInLoopInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.waitNotInLoop
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let loops: Set<String> = ["while_statement", "do_statement", "for_statement", "enhanced_for_statement"]
    private static let boundaries: Set<String> = [
        "method_declaration", "constructor_declaration", "lambda_expression", "class_body", "static_initializer",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), name.text == "wait",
              let arguments = node.child(byFieldName: "arguments"), arguments.namedChildCount <= 2 else { return }
        // `Object.wait` only: a receiver declared as another type has its own `wait`.
        if let object = node.child(byFieldName: "object"), object.type != "this" {
            guard let type = JavaDeclaredTypes.type(of: object), type.name == "Object", !type.isArray else { return }
        }
        var current = node.parent
        while let ancestor = current, !boundaries.contains(ancestor.type) {
            if loops.contains(ancestor.type) { return }
            current = ancestor.parent
        }
        report(JavaInspectionSupport.inspection(rule, message: "'wait()' should be called in a loop that re-checks its condition", node: name))
    }
}
