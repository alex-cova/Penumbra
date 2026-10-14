import EditorIntelligence
import Foundation

private let commentTypes: Set<String> = ["line_comment", "block_comment"]

/// The parameter names of a lambda, or nil for a shape this file does not handle.
private func lambdaParameterNames(_ lambda: SyntaxNode) -> [String]? {
    guard let parameters = lambda.child(byFieldName: "parameters") else { return nil }
    switch parameters.type {
    case "identifier":
        return [parameters.text]
    case "inferred_parameters":
        return parameters.namedChildren.filter { $0.type == "identifier" }.map(\.text)
    case "formal_parameters":
        let formals = parameters.namedChildren.filter { $0.type == "formal_parameter" }
        guard formals.count == parameters.namedChildCount else { return nil }
        return formals.compactMap { $0.child(byFieldName: "name")?.text }
    default:
        return nil
    }
}

/// `x -> Foo.bar(x)`, `() -> this.run()`, `s -> new Foo(s)`: a lambda that only forwards its parameters.
enum JavaLambdaCanBeMethodReferenceInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.lambdaCanBeMethodReference
    static let nodeTypes: Set<String> = ["lambda_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let replacement = replacement(for: node, context: context) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Lambda can be replaced with method reference '\(replacement)'", node: node,
            fixTitle: "Replace with '\(replacement)'"
        ))
    }

    private static func replacement(for lambda: SyntaxNode, context: JavaInspectionContext) -> String? {
        guard let names = lambdaParameterNames(lambda), let body = lambda.child(byFieldName: "body")?.unparenthesized,
              body.type != "block" else { return nil }
        switch body.type {
        case "method_invocation":
            guard let name = body.child(byFieldName: "name"), let object = body.child(byFieldName: "object"),
                  forwards(names, body.child(byFieldName: "arguments")),
                  isStableReceiver(object, parameters: names, context: context) else { return nil }
            return "\(object.text)::\(name.text)"
        case "object_creation_expression":
            guard body.child(byFieldName: "object") == nil, body.firstNamedChild(ofType: "class_body") == nil,
                  let type = body.child(byFieldName: "type"), forwards(names, body.child(byFieldName: "arguments")) else { return nil }
            let text = type.text.replacingOccurrences(of: "<>", with: "")
            return "\(text)::new"
        default:
            return nil
        }
    }

    /// The call's arguments are exactly the lambda's parameters, in order.
    private static func forwards(_ names: [String], _ arguments: SyntaxNode?) -> Bool {
        guard let arguments else { return false }
        let given = arguments.namedChildren
        return given.count == names.count && zip(given, names).allSatisfy { $0.type == "identifier" && $0.text == $1 }
    }

    /// A receiver whose value cannot change between creating the reference and calling it: a type
    /// name, `this`, or an effectively final local. Never one of the lambda's own parameters.
    private static func isStableReceiver(_ object: SyntaxNode, parameters: [String], context: JavaInspectionContext) -> Bool {
        var mentionsParameter = false
        if object.type == "identifier", parameters.contains(object.text) { mentionsParameter = true }
        object.forEachDescendant { if $0.type == "identifier", parameters.contains($0.text) { mentionsParameter = true } }
        guard !mentionsParameter else { return false }
        switch object.type {
        case "this":
            return true
        case "identifier":
            if object.text.first?.isUppercase == true { return true }
            return context.tree.declarationCache.fileSymbols(context: context).localOfUse[object.byteRange] != nil
        case "field_access":
            var root = object
            while root.type == "field_access", let inner = root.child(byFieldName: "object") { root = inner }
            return root.type == "identifier" && root.text.first?.isUppercase == true
        default:
            return false
        }
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let lambda = JavaInspectionSupport.node(of: "lambda_expression", for: diagnostic, tree: tree, source: source),
              let body = lambda.child(byFieldName: "body")?.unparenthesized, let names = lambdaParameterNames(lambda) else { return [] }
        let text: String
        switch body.type {
        case "method_invocation":
            guard let name = body.child(byFieldName: "name"), let object = body.child(byFieldName: "object"),
                  forwards(names, body.child(byFieldName: "arguments")) else { return [] }
            text = "\(object.text)::\(name.text)"
        case "object_creation_expression":
            guard let type = body.child(byFieldName: "type") else { return [] }
            text = "\(type.text.replacingOccurrences(of: "<>", with: ""))::new"
        default:
            return []
        }
        let edit = JavaInspectionSupport.edit(replacingBytes: lambda.byteRange, with: text, in: tree)
        return [CodeAction(title: "Replace with '\(text)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `x -> { return x + 1; }` and `x -> { foo(x); }`.
enum JavaLambdaBodyCanBeExpressionInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.lambdaBodyCanBeExpression
    static let nodeTypes: Set<String> = ["lambda_expression"]
    private static let statementExpressions: Set<String> = [
        "method_invocation", "assignment_expression", "update_expression", "object_creation_expression",
    ]

    /// The single expression a block body reduces to.
    private static func expression(of block: SyntaxNode) -> SyntaxNode? {
        guard block.type == "block", block.namedChildCount == 1, let only = block.namedChild(at: 0) else { return nil }
        switch only.type {
        case "return_statement":
            return only.namedChild(at: 0)
        case "expression_statement":
            guard let value = only.namedChild(at: 0), statementExpressions.contains(value.type) else { return nil }
            return value
        default:
            return nil
        }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let body = node.child(byFieldName: "body"), expression(of: body) != nil else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Statement lambda can be replaced with expression lambda", node: body,
            fixTitle: "Replace with expression lambda"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let block = JavaInspectionSupport.node(of: "block", for: diagnostic, tree: tree, source: source),
              let value = expression(of: block) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: block.byteRange, with: value.text, in: tree)
        return [CodeAction(title: "Replace with expression lambda", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `name.equals("x")` on a String variable: `"x".equals(name)` cannot throw.
enum JavaLiteralEqualsReversedInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.literalEqualsReversed
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let methods: Set<String> = ["equals", "equalsIgnoreCase"]

    private static func parts(of node: SyntaxNode) -> (object: SyntaxNode, literal: SyntaxNode, method: String)? {
        guard let name = node.child(byFieldName: "name"), methods.contains(name.text),
              let object = node.child(byFieldName: "object"), ["identifier", "field_access"].contains(object.type),
              let arguments = node.child(byFieldName: "arguments"), arguments.namedChildCount == 1,
              let literal = arguments.namedChild(at: 0), literal.type == "string_literal", literal.text != "\"\"",
              let type = JavaDeclaredTypes.type(of: object), type == .string else { return nil }
        return (object, literal, name.text)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let parts = parts(of: node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(parts.object.text).\(parts.method)(\(parts.literal.text))' can throw a NullPointerException", node: node,
            fixTitle: "Swap to \(parts.literal.text).\(parts.method)(\(parts.object.text))"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let parts = parts(of: node) else { return [] }
        let text = "\(parts.literal.text).\(parts.method)(\(parts.object.text))"
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: text, in: tree)
        return [CodeAction(title: "Swap to \(text)", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `int count = 0;` / `boolean done = false;` / `String name = null;` on a non-final field.
enum JavaRedundantFieldInitializerInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.redundantFieldInitializer
    static let nodeTypes: Set<String> = ["field_declaration"]
    private static let numericTypes: Set<String> = ["integral_type", "floating_point_type"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard !node.hasModifier("final"), let body = node.parent, ["class_body", "enum_body_declarations"].contains(body.type),
              let type = node.child(byFieldName: "type") else { return }
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let value = declarator.child(byFieldName: "value"), declarator.child(byFieldName: "dimensions") == nil,
                  isDefault(value, for: type) else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Field initializer '\(value.text)' is redundant", node: value, fixTitle: "Remove initializer"
            ))
        }
    }

    private static func isDefault(_ value: SyntaxNode, for type: SyntaxNode) -> Bool {
        switch value.type {
        case "null_literal":
            return !numericTypes.contains(type.type) && type.type != "boolean_type"
        case "false":
            return type.type == "boolean_type"
        case "character_literal":
            return type.text == "char" && value.text == "'\\u0000'"
        case "decimal_integer_literal", "hex_integer_literal", "octal_integer_literal", "binary_integer_literal",
             "decimal_floating_point_literal":
            guard numericTypes.contains(type.type) else { return false }
            var text = value.text.replacingOccurrences(of: "_", with: "").lowercased()
            if text.hasPrefix("0x") || text.hasPrefix("0b") {
                text = String(text.dropFirst(2))
                return !text.isEmpty && text.allSatisfy { $0 == "0" || $0 == "l" }
            }
            while let last = text.last, "lfd".contains(last) { text.removeLast() }
            return Double(text) == 0
        default:
            return false
        }
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        var current: SyntaxNode? = tree.node(atByteOffset: start)
        while let node = current, node.type != "variable_declarator" { current = node.parent }
        guard let declarator = current, let name = declarator.child(byFieldName: "name"),
              let value = declarator.child(byFieldName: "value") else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: name.endByte..<value.endByte, with: "", in: tree)
        return [CodeAction(title: "Remove initializer", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `super();` as the first statement of a constructor.
enum JavaUnnecessarySuperCallInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unnecessarySuperCall
    static let nodeTypes: Set<String> = ["explicit_constructor_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.children.contains(where: { $0.type == "super" }), node.child(byFieldName: "object") == nil,
              node.child(byFieldName: "arguments")?.namedChildCount == 0,
              let body = node.parent, body.type == "constructor_body", body.namedChildren.first?.byteRange == node.byteRange
        else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Unnecessary call to 'super()'", node: node, fixTitle: "Remove 'super()'"))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "explicit_constructor_invocation", for: diagnostic, tree: tree, source: source)
        else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: JavaSourceBytes.removalRange(of: node), with: "", in: tree)
        return [CodeAction(title: "Remove 'super()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `public` / `abstract` on an interface method, `public static final` on an interface field.
enum JavaRedundantInterfaceModifierInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.redundantInterfaceModifier
    static let nodeTypes: Set<String> = ["interface_body"]
    private static let redundant: [String: Set<String>] = [
        "method_declaration": ["public", "abstract"],
        "constant_declaration": ["public", "static", "final"],
        "class_declaration": ["public", "static"],
        "interface_declaration": ["public", "static"],
        "enum_declaration": ["public", "static"],
        "record_declaration": ["public", "static"],
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        for member in node.namedChildren {
            guard let banned = redundant[member.type], let modifiers = member.firstNamedChild(ofType: "modifiers") else { continue }
            // An interface method with a body must say what it is: `default`, `static` or `private`.
            for modifier in modifiers.children where banned.contains(modifier.type) {
                if member.type == "method_declaration", modifier.type == "abstract", member.child(byFieldName: "body") != nil { continue }
                report(JavaInspectionSupport.inspection(
                    rule, message: "Modifier '\(modifier.type)' is redundant for interface members", node: modifier,
                    fixTitle: "Remove '\(modifier.type)'"
                ))
            }
        }
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        var current: SyntaxNode? = tree.node(atByteOffset: start)
        while let node = current, node.type != "modifiers" { current = node.parent }
        guard let modifiers = current, let modifier = modifiers.children.first(where: { $0.startByte == start }) else { return [] }
        let bytes = tree.sourceBytes
        var end = modifier.endByte
        while end < bytes.count, bytes[end] == JavaSourceBytes.space || bytes[end] == JavaSourceBytes.tab { end += 1 }
        let edit = JavaInspectionSupport.edit(replacingBytes: modifier.startByte..<end, with: "", in: tree)
        return [CodeAction(title: "Remove '\(modifier.type)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `s.length() == 0` and its variants.
enum JavaStringLengthZeroCheckInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.stringLengthZeroCheck
    static let nodeTypes: Set<String> = ["binary_expression"]

    private struct Match {
        let receiver: SyntaxNode
        let isEmpty: Bool
    }

    private static func match(_ node: SyntaxNode) -> Match? {
        guard var op = node.operatorText, let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right") else { return nil }
        var call = left
        var literal = right
        if left.type == "decimal_integer_literal" {
            call = right
            literal = left
            switch op {
            case ">": op = "<"
            case "<": op = ">"
            case ">=": op = "<="
            case "<=": op = ">="
            default: break
            }
        }
        guard call.type == "method_invocation", literal.type == "decimal_integer_literal",
              call.child(byFieldName: "name")?.text == "length", call.child(byFieldName: "arguments")?.namedChildCount == 0,
              let receiver = call.child(byFieldName: "object"), ["identifier", "field_access"].contains(receiver.type),
              let type = JavaDeclaredTypes.type(of: receiver), type == .string, let number = Int(literal.text) else { return nil }
        switch (op, number) {
        case ("==", 0), ("<", 1), ("<=", 0): return Match(receiver: receiver, isEmpty: true)
        case ("!=", 0), (">", 0), (">=", 1): return Match(receiver: receiver, isEmpty: false)
        default: return nil
        }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let found = match(node) else { return }
        let replacement = (found.isEmpty ? "" : "!") + "\(found.receiver.text).isEmpty()"
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(node.text)' can be replaced with '\(replacement)'", node: node, fixTitle: "Replace with '\(replacement)'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source),
              let found = match(node) else { return [] }
        let replacement = (found.isEmpty ? "" : "!") + "\(found.receiver.text).isEmpty()"
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: replacement, in: tree)
        return [CodeAction(title: "Replace with '\(replacement)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
