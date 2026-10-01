import EditorIntelligence
import Foundation

enum JavaMathRandomCastInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.mathRandomCastToInt
    static let nodeTypes: Set<String> = ["cast_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "type")?.text == "int", let value = node.child(byFieldName: "value"),
              value.type == "method_invocation", value.child(byFieldName: "name")?.text == "random",
              let object = value.child(byFieldName: "object"), object.text == "Math" || object.text == "java.lang.Math",
              value.child(byFieldName: "arguments")?.namedChildCount == 0 else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'Math.random()' cast to 'int' is always 0", node: node))
    }
}

enum JavaThrowableNames {
    /// Names that read as throwables, plus classes this file declares as extending one.
    static func isThrowable(_ typeName: String, in root: SyntaxNode) -> Bool {
        var seen = Set<String>()
        var name = typeName
        while seen.insert(name).inserted {
            if name == "Throwable" || name.hasSuffix("Exception") || name.hasSuffix("Error") { return true }
            guard let superclass = declaredSuperclass(of: name, in: root) else { return false }
            name = superclass
        }
        return false
    }

    private static func declaredSuperclass(of name: String, in root: SyntaxNode) -> String? {
        var stack = [root]
        while let node = stack.popLast() {
            if node.type == "class_declaration", node.child(byFieldName: "name")?.text == name {
                return node.child(byFieldName: "superclass")?.namedChild(at: 0).map(JavaDeclaredTypes.simpleName(of:))
            }
            stack.append(contentsOf: node.namedChildren.reversed())
        }
        return nil
    }
}

/// `new X(...)` standing alone as a statement. An anonymous class body is something else, and
/// `case A -> new X();` yields the object.
private func bareCreation(_ node: SyntaxNode) -> (creation: SyntaxNode, typeName: String)? {
    guard node.parent?.type != "switch_rule", node.namedChildCount == 1, let creation = node.namedChild(at: 0), creation.type == "object_creation_expression",
          creation.namedChildren(ofType: "class_body").isEmpty,
          let type = creation.child(byFieldName: "type") else { return nil }
    return (creation, JavaDeclaredTypes.simpleName(of: type))
}

enum JavaThrowableNotThrownInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.throwableNotThrown
    static let nodeTypes: Set<String> = ["expression_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (creation, typeName) = bareCreation(node), JavaThrowableNames.isThrowable(typeName, in: context.tree.rootNode) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'\(typeName)' is created but not thrown", node: creation, fixTitle: "Add 'throw'"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let creation = JavaInspectionSupport.node(of: "object_creation_expression", for: diagnostic, tree: tree, source: source) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: creation.startByte..<creation.startByte, with: "throw ", in: tree)
        return [CodeAction(title: "Add 'throw'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaObjectAllocationIgnoredInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.resultOfObjectAllocationIgnored
    static let nodeTypes: Set<String> = ["expression_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (creation, typeName) = bareCreation(node), !JavaThrowableNames.isThrowable(typeName, in: context.tree.rootNode) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Result of 'new \(typeName)()' is ignored", node: creation))
    }
}

enum JavaStringBuilderCharArgumentInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.stringBuilderCharArgument
    static let nodeTypes: Set<String> = ["object_creation_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let type = node.child(byFieldName: "type"), ["StringBuilder", "StringBuffer"].contains(JavaDeclaredTypes.simpleName(of: type)),
              let arguments = node.child(byFieldName: "arguments"), arguments.namedChildCount == 1,
              let argument = arguments.namedChild(at: 0), JavaDeclaredTypes.type(of: argument)?.name == "char",
              JavaDeclaredTypes.type(of: argument)?.isArray == false else { return }
        let literal = argument.type == "character_literal"
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(JavaDeclaredTypes.simpleName(of: type))' constructor called with a 'char' sets the capacity, not the content",
            node: argument, fixTitle: literal ? "Replace with a string literal" : nil
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let literal = JavaInspectionSupport.node(of: "character_literal", for: diagnostic, tree: tree, source: source) else { return [] }
        var inner = String(literal.text.dropFirst().dropLast())
        if inner == "\\'" { inner = "'" } else if inner == "\"" { inner = "\\\"" }
        let edit = JavaInspectionSupport.edit(replacingBytes: literal.byteRange, with: "\"\(inner)\"", in: tree)
        return [CodeAction(title: "Replace with a string literal", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaArrayObjectMethodInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.arrayObjectMethodCall
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let arities = ["equals": 1, "hashCode": 0, "toString": 0]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name")?.text, let arity = arities[name],
              let object = node.child(byFieldName: "object"), JavaDeclaredTypes.type(of: object)?.isArray == true,
              node.child(byFieldName: "arguments")?.namedChildCount == arity else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(name)()' called on an array does not look at its elements", node: node, fixTitle: "Replace with 'Arrays.\(name)()'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let name = node.child(byFieldName: "name")?.text, let object = node.child(byFieldName: "object"),
              let arguments = node.child(byFieldName: "arguments") else { return [] }
        let call = "java.util.Arrays.\(name)(" + ([object] + arguments.namedChildren).map(\.text).joined(separator: ", ") + ")"
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: call, in: tree)
        return [CodeAction(title: "Replace with 'Arrays.\(name)()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
