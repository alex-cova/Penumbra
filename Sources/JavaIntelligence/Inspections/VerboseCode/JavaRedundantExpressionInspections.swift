import EditorIntelligence
import Foundation

enum JavaRedundantLocalVariableInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.redundantLocalVariable
    static let nodeTypes: Set<String> = ["local_variable_declaration"]
    /// Types whose literal initializer boxes differently once it is returned as an `Object`.
    private static let narrowTypes: Set<String> = ["byte", "short", "char", "long", "float"]
    private static let literals: Set<String> = [
        "decimal_integer_literal", "hex_integer_literal", "octal_integer_literal", "binary_integer_literal", "character_literal",
        "decimal_floating_point_literal",
    ]

    /// The variable's name, its initializer and the `return x;` / `throw x;` that follows it.
    private static func candidate(_ node: SyntaxNode) -> (name: SyntaxNode, value: SyntaxNode, terminator: SyntaxNode)? {
        guard node.parent?.type == "block", !node.hasAnnotation else { return nil }
        let declarators = node.namedChildren(ofType: "variable_declarator")
        guard declarators.count == 1, let declarator = declarators.first, declarator.child(byFieldName: "dimensions") == nil,
              let name = declarator.child(byFieldName: "name"), let value = declarator.child(byFieldName: "value"),
              !["array_initializer", "lambda_expression", "method_reference"].contains(value.type),
              let next = node.nextNamedSibling, next.type == "return_statement" || next.type == "throw_statement",
              next.namedChildCount == 1, let operand = next.namedChild(at: 0), operand.type == "identifier", operand.text == name.text
        else { return nil }
        if let type = node.child(byFieldName: "type"), narrowTypes.contains(type.text), literals.contains(value.unparenthesized.type) { return nil }
        return (name, value, next)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (name, _, terminator) = candidate(node) else { return }
        let verb = terminator.type == "return_statement" ? "returned" : "thrown"
        report(JavaInspectionSupport.inspection(
            rule, message: "Local variable '\(name.text)' is \(verb) immediately after its declaration", node: name, fixTitle: "Inline variable"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let owner = JavaClassShape.declaration(for: diagnostic, tree: tree, source: source), owner.type == "local_variable_declaration",
              let (_, value, terminator) = candidate(owner) else { return [] }
        let keyword = terminator.type == "return_statement" ? "return" : "throw"
        let edit = JavaInspectionSupport.edit(replacingBytes: owner.startByte..<terminator.endByte, with: "\(keyword) \(value.text);", in: tree)
        return [CodeAction(title: "Inline variable", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaRedundantStringOperationInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.redundantStringOperation
    static let nodeTypes: Set<String> = ["method_invocation", "object_creation_expression"]
    private static let simple: Set<String> = [
        "identifier", "string_literal", "field_access", "method_invocation", "parenthesized_expression", "array_access", "this",
    ]
    private static let statementContexts: Set<String> = [
        "variable_declarator", "argument_list", "return_statement", "expression_statement", "parenthesized_expression",
    ]

    /// The String expression the call or creation can be replaced with, and what the operation was.
    private static func redundancy(of node: SyntaxNode) -> (operand: SyntaxNode, what: String)? {
        if node.type == "object_creation_expression" {
            guard node.namedChildren(ofType: "class_body").isEmpty, node.child(byFieldName: "object") == nil,
                  node.child(byFieldName: "type")?.text == "String", let arguments = node.child(byFieldName: "arguments"),
                  arguments.namedChildCount == 1, let argument = arguments.namedChild(at: 0),
                  argument.type == "string_literal" || JavaDeclaredTypes.type(of: argument) == .string else { return nil }
            return (argument, "new String(String)")
        }
        guard let name = node.child(byFieldName: "name")?.text, let object = node.child(byFieldName: "object"),
              object.type == "string_literal" || JavaDeclaredTypes.type(of: object) == .string,
              let arguments = node.child(byFieldName: "arguments") else { return nil }
        if name == "toString", arguments.namedChildCount == 0 { return (object, "toString()") }
        if name == "substring", arguments.namedChildCount == 1, arguments.namedChild(at: 0)?.text == "0" { return (object, "substring(0)") }
        return nil
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (_, what) = redundancy(of: node) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Redundant '\(what)' on a String", node: node, fixTitle: "Remove redundant call"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source)
            ?? JavaInspectionSupport.node(of: "object_creation_expression", for: diagnostic, tree: tree, source: source)
        guard let node, let (operand, _) = redundancy(of: node) else { return [] }
        let needsParentheses = !simple.contains(operand.type) && !statementContexts.contains(node.parent?.type ?? "")
        let text = needsParentheses ? "(\(operand.text))" : operand.text
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: text, in: tree)
        return [CodeAction(title: "Remove redundant call", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
