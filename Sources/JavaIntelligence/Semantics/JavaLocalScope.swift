import Foundation

/// A local variable, parameter, loop variable, or resource variable visible at some point in a
/// method/constructor body.
/// Where an implicitly typed lambda parameter came from: the call it's an argument of, so its
/// type can be read off that parameter's functional interface.
public struct JavaLambdaOrigin: Sendable, Equatable {
    /// Source of the whole `receiver.method(..., lambda, ...)` call.
    public let invocationText: String
    public let argumentIndex: Int
    public let parameterIndex: Int
}

public struct JavaLocalVariable: Sendable, Equatable {
    public let name: String
    public let type: JavaTypeRef
    /// Source text of the initializer for a `var` declaration, so ``JavaExpressionTyper`` can
    /// infer its type on demand; `nil` otherwise.
    public let initializerText: String?
    /// Set for implicitly typed lambda parameters passed straight to a method call.
    public let lambdaOrigin: JavaLambdaOrigin?

    public init(name: String, type: JavaTypeRef, initializerText: String? = nil, lambdaOrigin: JavaLambdaOrigin? = nil) {
        self.name = name
        self.type = type
        self.initializerText = initializerText
        self.lambdaOrigin = lambdaOrigin
    }

    /// Declared with `var`, so ``type`` carries no information until the initializer is typed.
    public var isVarDeclaration: Bool {
        if case .unresolved("var", _) = type { return true }
        return false
    }
}

/// Collects the locals visible at a byte offset in a live (possibly still-being-typed) source
/// file: method/constructor parameters, local variable declarations in enclosing blocks that occur
/// textually before the offset, enhanced-for loop variables, and try-with-resources variables --
/// by walking up the tree from the offset through its ancestors.
///
/// Best-effort by design: a trigger `.` with nothing typed after it, on anything more than a bare
/// identifier (a field chain like `bar.value.`, `this.`, a method-call chain, ...), reliably
/// collapses the *entire* enclosing declaration into one `ERROR` node at the file's root instead of
/// staying contained in its block (confirmed empirically -- see `JavaReceiverScanner`'s doc
/// comment). tree-sitter still attaches whatever fields it matched before giving up directly onto
/// that `ERROR` node, so a `parameters:` field survives even when the method's `body:`/`block`
/// wrapper is lost entirely -- meaning any local variable declared earlier in the same corrupted
/// method body is genuinely unrecoverable from this parse, not just harder to reach. This collector
/// still recovers parameters in that case (the most common thing a receiver chain continues from),
/// documented here rather than silently missing locals with no explanation.
///
/// Also collected: classic `for` init variables, catch parameters (a multi-catch binds its first
/// alternative's type), implicitly typed lambda parameters (typed `Object` -- no functional
/// interface inference), `instanceof` pattern bindings in enclosing `if`/`while` conditions and in
/// earlier `&&` operands, and locals declared earlier in a `switch` statement group.
public enum JavaLocalScope {
    public static func locals(in tree: JavaSyntaxTree, atByteOffset offset: Int) -> [JavaLocalVariable] {
        var result: [JavaLocalVariable] = []
        var seenNames = Set<String>() // innermost/first-encountered declaration wins on shadowing.
        var current: SyntaxNode? = tree.node(atByteOffset: offset)

        while let node = current {
            switch node.type {
            case "block", "constructor_body", "switch_block_statement_group":
                for statement in node.namedChildren where statement.type == "local_variable_declaration" && statement.endByte <= offset {
                    collectLocalVariableDeclaration(statement, into: &result, seenNames: &seenNames)
                }
            case "for_statement":
                if let initializer = node.child(byFieldName: "init"), initializer.type == "local_variable_declaration",
                   offset >= initializer.endByte {
                    collectLocalVariableDeclaration(initializer, into: &result, seenNames: &seenNames)
                }
            case "catch_clause":
                if let parameter = node.firstNamedChild(ofType: "catch_formal_parameter"),
                   let nameNode = parameter.child(byFieldName: "name"),
                   let body = node.child(byFieldName: "body"), offset >= body.startByte {
                    let firstType = parameter.firstNamedChild(ofType: "catch_type")?.namedChild(at: 0)
                    let type = firstType.map(JavaTypeNodeConverter.convert) ?? .unresolved(simpleName: "Throwable", arguments: [])
                    addIfNew(name: nameNode.text, type: type, into: &result, seenNames: &seenNames)
                }
            case "if_statement", "while_statement":
                if let condition = node.child(byFieldName: "condition"), offset >= condition.endByte {
                    collectPatternBindings(in: condition, before: Int.max, into: &result, seenNames: &seenNames)
                }
            case "binary_expression":
                // `o instanceof String s && s.` -- bindings of the left operand are in scope on the right.
                if let left = node.child(byFieldName: "left"), offset >= left.endByte {
                    collectPatternBindings(in: left, before: offset, into: &result, seenNames: &seenNames)
                }
            case "method_declaration", "constructor_declaration":
                if let parameters = node.child(byFieldName: "parameters") {
                    for parameter in parameters.namedChildren where parameter.type == "formal_parameter" {
                        collectFormalParameter(parameter, into: &result, seenNames: &seenNames)
                    }
                }
            case "lambda_expression":
                if let parameters = node.child(byFieldName: "parameters"), parameters.type == "formal_parameters" {
                    for parameter in parameters.namedChildren where parameter.type == "formal_parameter" {
                        collectFormalParameter(parameter, into: &result, seenNames: &seenNames)
                    }
                } else {
                    // `x -> ...` / `(a, b) -> ...`: implicitly typed. Typed `Object` here; when the
                    // lambda is a call argument, the origin lets `JavaExpressionTyper` read the real
                    // type off the called method's functional-interface parameter.
                    let origin = lambdaCallSite(of: node)
                    let names: [SyntaxNode]
                    if let parameters = node.child(byFieldName: "parameters"), parameters.type == "inferred_parameters" {
                        names = parameters.namedChildren.filter { $0.type == "identifier" }
                    } else if let single = node.child(byFieldName: "parameters"), single.type == "identifier" {
                        names = [single]
                    } else {
                        names = []
                    }
                    for (position, identifier) in names.enumerated() {
                        let lambdaOrigin = origin.map { JavaLambdaOrigin(invocationText: $0.text, argumentIndex: $0.argumentIndex, parameterIndex: position) }
                        addIfNew(
                            name: identifier.text, type: .unresolved(simpleName: "Object", arguments: []), lambdaOrigin: lambdaOrigin,
                            into: &result, seenNames: &seenNames
                        )
                    }
                }
            case "ERROR":
                // tree-sitter's debug printer (`ts_node_string`) shows field labels like
                // `parameters:` on an ERROR node's children, but `ts_node_child_by_field_name`
                // doesn't actually resolve them there (confirmed empirically) -- those labels are
                // cosmetic on ERROR nodes, not queryable fields. Found by node type instead.
                if let parameters = node.namedChildren.first(where: { $0.type == "formal_parameters" }) {
                    for parameter in parameters.namedChildren where parameter.type == "formal_parameter" {
                        collectFormalParameter(parameter, into: &result, seenNames: &seenNames)
                    }
                }
            case "enhanced_for_statement":
                if let body = node.child(byFieldName: "body"), offset >= body.startByte,
                   let typeNode = node.child(byFieldName: "type"), let nameNode = node.child(byFieldName: "name") {
                    addIfNew(name: nameNode.text, type: JavaTypeNodeConverter.convert(typeNode), into: &result, seenNames: &seenNames)
                }
            case "try_with_resources_statement":
                if let spec = node.firstNamedChild(ofType: "resource_specification") {
                    for resource in spec.namedChildren where resource.type == "resource" {
                        guard let typeNode = resource.child(byFieldName: "type"), let nameNode = resource.child(byFieldName: "name") else { continue }
                        addIfNew(name: nameNode.text, type: JavaTypeNodeConverter.convert(typeNode), into: &result, seenNames: &seenNames)
                    }
                }
            default:
                break
            }
            current = node.parent
        }
        return result
    }

    /// `var x = ...;` declarations keep `.unresolved(simpleName: "var")` as their type -- typing
    /// the initializer is `JavaExpressionTyper`'s job -- and carry the initializer's source text so
    /// the typer can infer it when the local is used as a receiver.
    private static func collectLocalVariableDeclaration(_ node: SyntaxNode, into result: inout [JavaLocalVariable], seenNames: inout Set<String>) {
        guard let typeNode = node.child(byFieldName: "type") else { return }
        let type = JavaTypeNodeConverter.convert(typeNode)
        let isVar = typeNode.text == "var"
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let nameNode = declarator.child(byFieldName: "name") else { continue }
            let initializer = isVar ? declarator.child(byFieldName: "value")?.text : nil
            let declaredType: JavaTypeRef = isVar ? .unresolved(simpleName: "var", arguments: []) : type
            addIfNew(name: nameNode.text, type: declaredType, initializerText: initializer, into: &result, seenNames: &seenNames)
        }
    }

    /// `x instanceof Foo f` bindings anywhere inside `node` (conditions joined by `&&`, parentheses).
    private static func collectPatternBindings(in node: SyntaxNode, before offset: Int, into result: inout [JavaLocalVariable], seenNames: inout Set<String>) {
        if node.type == "instanceof_expression", node.endByte <= offset,
           let nameNode = node.child(byFieldName: "name"), let typeNode = node.child(byFieldName: "right") {
            addIfNew(name: nameNode.text, type: JavaTypeNodeConverter.convert(typeNode), into: &result, seenNames: &seenNames)
        }
        for child in node.namedChildren where child.type != "lambda_expression" && child.startByte < offset {
            collectPatternBindings(in: child, before: offset, into: &result, seenNames: &seenNames)
        }
    }

    private static func collectFormalParameter(_ node: SyntaxNode, into result: inout [JavaLocalVariable], seenNames: inout Set<String>) {
        guard let typeNode = node.child(byFieldName: "type"), let nameNode = node.child(byFieldName: "name") else { return }
        addIfNew(name: nameNode.text, type: JavaTypeNodeConverter.convert(typeNode), into: &result, seenNames: &seenNames)
    }

    private static func addIfNew(
        name: String, type: JavaTypeRef, initializerText: String? = nil, lambdaOrigin: JavaLambdaOrigin? = nil,
        into result: inout [JavaLocalVariable], seenNames: inout Set<String>
    ) {
        guard seenNames.insert(name).inserted else { return }
        result.append(JavaLocalVariable(name: name, type: type, initializerText: initializerText, lambdaOrigin: lambdaOrigin))
    }

    /// The `method_invocation` a lambda is a direct argument of, and its argument position.
    private static func lambdaCallSite(of lambda: SyntaxNode) -> (text: String, argumentIndex: Int)? {
        guard let argumentList = lambda.parent, argumentList.type == "argument_list",
              let invocation = argumentList.parent, invocation.type == "method_invocation",
              let position = argumentList.namedChildren.firstIndex(where: { $0.startByte == lambda.startByte && $0.endByte == lambda.endByte }) else {
            return nil
        }
        return (invocation.text, position)
    }
}
