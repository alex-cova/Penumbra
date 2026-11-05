import Foundation

/// Where an implicitly typed lambda parameter came from: what the lambda is assigned or passed to,
/// so its type can be read off that target's functional interface.
public struct JavaLambdaOrigin: Sendable, Equatable {
    public let target: JavaExpressionTarget
    public let parameterIndex: Int
}

/// The type an expression is converted to by its surroundings, as written in the source: what
/// Java calls the target type of a poly expression (a lambda, a generic method call).
public indirect enum JavaExpressionTarget: Sendable, Equatable {
    /// `Function<A, B> f = <expr>`, `(Type) <expr>`, `return <expr>` in a method returning `Type`.
    case declaredType(JavaTypeRef)
    /// `field = <expr>`: the type of the left-hand side, typed on demand.
    case assignedTo(expressionText: String)
    /// Argument `argumentIndex` of the call `callText`, which may itself have a target
    /// (`users.sort(Comparator.comparing(<expr>))`).
    case argument(callText: String, argumentIndex: Int, callTarget: JavaExpressionTarget?)
}

/// A local variable, parameter, loop variable, resource variable or pattern binding visible at some
/// point in a method or constructor body (see ``JavaScopeTree``, ``JavaSyntaxTree/visibleLocals(atByteOffset:)``).
public struct JavaLocalVariable: Sendable, Equatable {
    public let name: String
    public let type: JavaTypeRef
    /// Source text of the initializer for a `var` declaration, so ``JavaExpressionTyper`` can
    /// infer its type on demand; `nil` otherwise.
    public let initializerText: String?
    /// Set for implicitly typed lambda parameters passed straight to a method call.
    public let lambdaOrigin: JavaLambdaOrigin?
    /// `for (var x : items)`: ``initializerText`` is the iterated expression, and the local has
    /// its element type rather than its type.
    public let isIterationVariable: Bool

    public init(
        name: String, type: JavaTypeRef, initializerText: String? = nil, lambdaOrigin: JavaLambdaOrigin? = nil,
        isIterationVariable: Bool = false
    ) {
        self.name = name
        self.type = type
        self.initializerText = initializerText
        self.lambdaOrigin = lambdaOrigin
        self.isIterationVariable = isIterationVariable
    }

    /// Declared with `var`, so ``type`` carries no information until the initializer is typed.
    public var isVarDeclaration: Bool {
        if case .unresolved("var", _) = type { return true }
        return false
    }
}

extension JavaExpressionTarget {
    /// The target `node` is converted to, from the syntax around it: a call argument, a declared
    /// variable, an assignment, a cast, or a `return` in a method. `nil` when the surroundings say
    /// nothing (an expression statement, a `var` declaration, a `return` inside a lambda).
    static func target(of node: SyntaxNode) -> JavaExpressionTarget? {
        guard let parent = node.parent else { return nil }
        switch parent.type {
        case "argument_list":
            guard let invocation = parent.parent, invocation.type == "method_invocation",
                  let position = parent.namedChildren.firstIndex(where: { $0.startByte == node.startByte && $0.endByte == node.endByte }) else {
                return nil
            }
            return .argument(callText: invocation.text, argumentIndex: position, callTarget: target(of: invocation))
        case "variable_declarator":
            guard parent.child(byFieldName: "value")?.startByte == node.startByte,
                  let declaration = parent.parent, let typeNode = declaration.child(byFieldName: "type"), typeNode.text != "var",
                  typeNode.text != "val" || !JavaLombokMembers.importsLombok(node) else { return nil }
            return .declaredType(JavaTypeNodeConverter.convert(typeNode))
        case "assignment_expression":
            guard parent.child(byFieldName: "right")?.startByte == node.startByte, let left = parent.child(byFieldName: "left") else { return nil }
            return .assignedTo(expressionText: left.text)
        case "cast_expression":
            return parent.child(byFieldName: "type").map { .declaredType(JavaTypeNodeConverter.convert($0)) }
        case "parenthesized_expression":
            return target(of: parent)
        case "ternary_expression":
            guard parent.child(byFieldName: "condition")?.startByte != node.startByte else { return nil }
            return target(of: parent)
        case "return_statement":
            var current = parent.parent
            while let ancestor = current {
                switch ancestor.type {
                case "lambda_expression", "class_body":
                    return nil
                case "method_declaration":
                    guard let typeNode = ancestor.child(byFieldName: "type") else { return nil }
                    return .declaredType(JavaTypeNodeConverter.convert(typeNode))
                default:
                    current = ancestor.parent
                }
            }
            return nil
        default:
            return nil
        }
    }
}
