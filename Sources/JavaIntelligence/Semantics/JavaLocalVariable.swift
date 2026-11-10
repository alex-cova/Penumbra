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
        case "ERROR":
            return recoveredCallArgumentTarget(of: node, in: parent)
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

    // MARK: - A lambda that error recovery left outside its call

    /// How far back from a lambda the damaged region is read for its call. A statement-sized window:
    /// the scan is per lambda in an `ERROR` node, never per request, but it must not grow with the file.
    private static let recoveryWindow = 4096
    private static let statementContainers: Set<String> = ["block", "class_body", "program", "switch_block", "constructor_body"]

    /// The target of a lambda whose call tree-sitter could not build.
    ///
    /// With a lambda block that is never closed (`build(s, (l, v) -> {\n  l.`, the file's own `}` pairing
    /// with the wrong brace) the grammar gives up on the call: the lambdas survive as children of an
    /// `ERROR` node beside the callee's name, with no `method_invocation` and no `argument_list`, so the
    /// parameters would be typed `Object`. Everything needed is still in the text: the `(` that opens the
    /// call, what stands before it, and the arguments before the lambda. They are read off the bytes of
    /// the damaged region by one forward pass (strings, characters and comments skipped), and the call is
    /// rebuilt as `callee(earlier arguments, <lambda parameters> -> {})`. The lambda's body is left out
    /// on purpose: the inference never types the argument it is asked about, and a body that is itself
    /// damaged would only stop the rebuilt call from parsing. Arguments after the lambda are unknown here.
    ///
    /// `nil` when the lambda is not an argument of a call (the innermost open bracket is not a `(`), the
    /// call is a constructor (`new X(`) or its callee cannot be read, or the region is longer than
    /// ``recoveryWindow`` and starts mid-statement; the parameters then keep the type `Object` they had before.
    static func recoveredCallArgumentTarget(of lambda: SyntaxNode, in error: SyntaxNode) -> JavaExpressionTarget? {
        guard lambda.type == "lambda_expression" else { return nil }
        let bytes = lambda.tree.sourceBytes
        let lambdaStart = lambda.startByte
        // The callee can sit outside the `ERROR` that holds the lambda (an inner one may start at the `(`,
        // with `users.stream().map(...).forEach` in the statement around it), so read from the start of the
        // statement. When that is longer than the window, start at a line start inside it: only the
        // innermost open bracket matters, and it is within the window.
        var outermost = error
        while let enclosing = outermost.parent, !Self.statementContainers.contains(enclosing.type) { outermost = enclosing }
        var begin = outermost.startByte
        guard begin < lambdaStart, lambdaStart <= bytes.count else { return nil }
        if lambdaStart - begin > recoveryWindow {
            begin = lambdaStart - recoveryWindow
            while begin < lambdaStart, bytes[begin] != 0x0A { begin += 1 }
            begin += 1
            guard begin < lambdaStart else { return nil }
        }

        // Forward pass: which brackets are open at the lambda, and where each argument of an open `(` starts.
        struct Open {
            let byte: UInt8
            let position: Int
            var argumentStarts: [Int]
        }
        var open: [Open] = []
        var index = begin
        while index < lambdaStart {
            let byte = bytes[index]
            switch byte {
            case 0x22, 0x27:                                    // " '
                index += 1
                while index < lambdaStart, bytes[index] != byte {
                    if bytes[index] == 0x5C { index += 1 }
                    index += 1
                }
            case 0x2F where index + 1 < lambdaStart && bytes[index + 1] == 0x2F:       // //
                while index < lambdaStart, bytes[index] != 0x0A { index += 1 }
            case 0x2F where index + 1 < lambdaStart && bytes[index + 1] == 0x2A:       // /* */
                index += 2
                while index + 1 < lambdaStart, !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) { index += 1 }
                index += 1
            case 0x28, 0x7B, 0x5B:                              // ( { [
                open.append(Open(byte: byte, position: index, argumentStarts: [index + 1]))
            case 0x29, 0x7D, 0x5D:                              // ) } ]
                let opener: UInt8 = byte == 0x29 ? 0x28 : (byte == 0x7D ? 0x7B : 0x5B)
                if let match = open.lastIndex(where: { $0.byte == opener }) { open.removeSubrange(match...) }
            case 0x2C:                                          // ,
                if let last = open.indices.last, open[last].byte == 0x28 { open[last].argumentStarts.append(index + 1) }
            default:
                break
            }
            index += 1
        }
        guard let call = open.last, call.byte == 0x28, let argumentStart = call.argumentStarts.last,
              bytes[argumentStart..<lambdaStart].allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }),
              let calleeStart = calleeStart(before: call.position, in: bytes, lowerBound: begin) else { return nil }

        func text(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var arguments: [String] = []
        for (position, start) in call.argumentStarts.dropLast().enumerated() {
            let end = call.argumentStarts[position + 1] - 1      // the comma
            arguments.append(text(start..<end))
        }
        let parameters = lambda.child(byFieldName: "parameters")?.text ?? "()"
        arguments.append("\(parameters) -> {}")
        let callText = text(calleeStart..<call.position) + "(" + arguments.joined(separator: ", ") + ")"
        return .argument(callText: callText, argumentIndex: arguments.count - 1, callTarget: nil)
    }

    /// Where the callee expression that ends at the `(` at `paren` starts: a name, optionally behind
    /// `receiver.`, `call(...).` or `.<T>` segments, read backwards. `nil` for `new Type(` and when
    /// nothing that looks like a name stands there.
    private static func calleeStart(before paren: Int, in bytes: [UInt8], lowerBound: Int) -> Int? {
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        func isIdentifier(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x24 || byte >= 0x80
        }
        /// Moves `position` back over one balanced group that ends just before it.
        func skipGroup(_ position: inout Int, close: UInt8, open: UInt8) -> Bool {
            var depth = 0
            while position > lowerBound {
                position -= 1
                if bytes[position] == close { depth += 1 } else if bytes[position] == open {
                    depth -= 1
                    if depth == 0 { return true }
                }
            }
            return false
        }
        var position = paren
        while true {
            while position > lowerBound, isSpace(bytes[position - 1]) { position -= 1 }
            if position > lowerBound, bytes[position - 1] == 0x29 {                    // `call(...)` before the name
                guard skipGroup(&position, close: 0x29, open: 0x28) else { return nil }
                while position > lowerBound, isSpace(bytes[position - 1]) { position -= 1 }
            }
            let nameEnd = position
            while position > lowerBound, isIdentifier(bytes[position - 1]) { position -= 1 }
            guard position < nameEnd else { return nil }
            var before = position
            while before > lowerBound, isSpace(bytes[before - 1]) { before -= 1 }
            // `new Thread(`: a constructor call is not a method call.
            if before - 3 >= lowerBound, String(decoding: bytes[(before - 3)..<before], as: UTF8.self) == "new",
               before - 3 == lowerBound || !isIdentifier(bytes[before - 4]) { return nil }
            // `receiver.<T>name(`: the type arguments sit between the dot and the name.
            if before > lowerBound, bytes[before - 1] == 0x3E {
                guard skipGroup(&before, close: 0x3E, open: 0x3C) else { return nil }
                while before > lowerBound, isSpace(bytes[before - 1]) { before -= 1 }
            }
            guard before > lowerBound, bytes[before - 1] == 0x2E else { return position }   // no `.`: the chain starts here
            position = before - 1
        }
    }
}
