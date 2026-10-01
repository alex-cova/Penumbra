import EditorIntelligence
import Foundation

enum JavaPrintStackTraceInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.printStackTraceCall
    static let nodeTypes: Set<String> = ["method_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name")?.text, node.child(byFieldName: "arguments")?.namedChildCount == 0,
              let object = node.child(byFieldName: "object") else { return }
        if name == "printStackTrace", object.type == "identifier" || object.type == "field_access" {
            report(JavaInspectionSupport.inspection(rule, message: "Call to 'printStackTrace()'; log the exception instead", node: node))
        } else if name == "dumpStack", object.text == "Thread" {
            report(JavaInspectionSupport.inspection(rule, message: "Call to 'Thread.dumpStack()'; log the stack trace instead", node: node))
        }
    }
}

enum JavaSystemOutErrInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.systemOutErr
    static let nodeTypes: Set<String> = ["field_access"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "object")?.text == "System", let field = node.child(byFieldName: "field")?.text,
              field == "out" || field == "err" else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Uses of 'System.\(field)' should be replaced with logging", node: node))
    }
}

enum JavaSystemGcInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.systemGcCall
    static let nodeTypes: Set<String> = ["method_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "name")?.text == "gc", node.child(byFieldName: "arguments")?.namedChildCount == 0,
              let object = node.child(byFieldName: "object") else { return }
        let isSystem = object.text == "System"
        let isRuntime = object.type == "method_invocation" && object.text.replacingOccurrences(of: " ", with: "").hasSuffix("Runtime.getRuntime()")
        guard isSystem || isRuntime else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Explicit garbage collection with '\(isSystem ? "System" : "Runtime").gc()' is rarely a good idea", node: node
        ))
    }
}

enum JavaObsoleteCollectionInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.obsoleteCollection
    static let nodeTypes: Set<String> = ["object_creation_expression"]
    private static let replacements = ["Vector": "ArrayList", "Hashtable": "HashMap", "Stack": "ArrayDeque"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let type = node.child(byFieldName: "type") else { return }
        let name = JavaDeclaredTypes.simpleName(of: type)
        guard let replacement = replacements[name] else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Obsolete collection '\(name)' used; consider '\(replacement)'", node: type))
    }
}

enum JavaFinalizeDeclaredInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.finalizeDeclared
    static let nodeTypes: Set<String> = ["method_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "name")?.text == "finalize", node.child(byFieldName: "parameters")?.namedChildCount == 0,
              let name = node.child(byFieldName: "name") else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'finalize()' is deprecated for removal; use try-with-resources or a Cleaner", node: name))
    }
}
