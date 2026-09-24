import Foundation

/// The result of typing a receiver expression: its type, and whether it's a type reference
/// (`Foo.`, a bare class name used as a qualifier -- only static members/nested types make sense)
/// or a value (`foo.`, an instance -- everything else).
public struct JavaReceiverInfo: Sendable, Equatable {
    public let type: JavaTypeRef
    public let isTypeReference: Bool
    /// Set when the receiver is a package prefix (`java.util.`), not a type or a value.
    public let packageName: String?

    public init(type: JavaTypeRef, isTypeReference: Bool, packageName: String? = nil) {
        self.type = type
        self.isTypeReference = isTypeReference
        self.packageName = packageName
    }
}

/// Infers the type of the expression immediately before a `.` (or other member-access trigger) in
/// a live buffer -- the piece that turns "cursor is right after `list.stream().filter(x -> x > 0).`
/// in this file" into "the receiver is a `Stream<String>`, so offer `Stream`'s members".
///
/// Two things make this harder than parsing a complete file:
/// 1. The dangling trailing `.` (nothing typed after it yet) can corrupt tree-sitter's error
///    recovery for the *whole* enclosing declaration, not just the current statement -- see
///    ``JavaReceiverScanner``'s doc comment. The receiver text is therefore extracted by that
///    scanner and re-parsed on its own, wrapped in a tiny syntactically-complete synthetic snippet,
///    never re-parsing the live buffer's dangling dot directly.
/// 2. Locals in scope at the cursor (which the receiver might reference) come from the *real*
///    file's tree, via ``JavaLocalScope``, since the synthetic snippet obviously has none of its
///    own.
///
/// Lambdas and method references passed to a call are typed against the functional interface of
/// the parameter they land in (`map(StockSet::getUuid)` binds `R` to `UUID`), and implicitly typed
/// lambda parameters take that interface's parameter types (`forEach(item -> item.|)`).
///
/// Known simplifications (documented rather than silently wrong): overloads are chosen by arity,
/// then by how many argument types agree (erased names only); a generic method's type variables
/// are never bound from the assignment target; a chain that bottoms out in something this can't
/// type (an unindexed class, a language feature not covered below) returns `nil` rather than
/// guessing.
public enum JavaExpressionTyper {
    /// `source`/`realTree` are the live file being edited; `dotOffset` is the byte offset of the
    /// `.` (or other trigger character) itself. Returns the receiver's resolved type, or `nil` if
    /// there's no receiver, it can't be parsed, or it can't be typed.
    public static func typeOfReceiver(
        source: String, realTree: JavaSyntaxTree, dotOffset: Int, context: JavaResolutionContext, index: JavaIndex
    ) async -> JavaTypeRef? {
        await receiverInfo(source: source, realTree: realTree, dotOffset: dotOffset, context: context, index: index)?.type
    }

    /// Like ``typeOfReceiver(source:realTree:dotOffset:context:index:)``, but also says whether the
    /// receiver is a type reference (`Foo.`, only static members make sense) or a value (`foo.`,
    /// everything else) -- callers driving member completion (rather than just wanting a type)
    /// need this to pick ``JavaMemberLookupMode`` correctly.
    public static func receiverInfo(
        source: String, realTree: JavaSyntaxTree, dotOffset: Int, context: JavaResolutionContext, index: JavaIndex
    ) async -> JavaReceiverInfo? {
        let bytes = Array(source.utf8)
        guard let range = treeReceiverRange(in: realTree, dotOffset: dotOffset) ?? JavaReceiverScanner.receiverRange(in: bytes, dotOffset: dotOffset) else { return nil }
        let receiverText = String(decoding: bytes[range], as: UTF8.self)
        if receiverText == "super" {
            // `super;` alone isn't a statement tree-sitter will parse as an expression.
            guard let selfName = context.enclosingTypeQualifiedNames.first,
                  let superclass = await JavaMemberLookup.directSuperclass(of: selfName, context: context, index: index) else { return nil }
            return JavaReceiverInfo(type: superclass, isTypeReference: false)
        }
        guard let syntheticTree = JavaSyntaxParser().parse("class __Synthetic__ { void __m__() { \(receiverText); } }"),
              let exprNode = outermostExpression(in: syntheticTree.rootNode) else {
            return nil
        }
        let locals = JavaLocalScope.locals(in: realTree, atByteOffset: dotOffset)
        guard let result = await typed(exprNode, locals: locals, context: context, index: index) else { return nil }
        if let packageName = result.packageName {
            return JavaReceiverInfo(type: .unresolved(simpleName: packageName, arguments: []), isTypeReference: true, packageName: packageName)
        }
        return JavaReceiverInfo(type: result.type, isTypeReference: result.isTypeReference)
    }

    /// The receiver's byte range read off the parse tree: completion parses with a dummy
    /// identifier after the dot, so `receiver.__penumbra__` is usually a clean `field_access`,
    /// `method_invocation` or `method_reference` whose object child is the receiver, however it is
    /// spread over lines or interleaved with comments. `nil` when that part of the tree has errors
    /// (the text scan in ``JavaReceiverScanner`` is the fallback) or when `realTree` has no
    /// expression continuing past this dot.
    static func treeReceiverRange(in realTree: JavaSyntaxTree, dotOffset: Int) -> Range<Int>? {
        var current: SyntaxNode? = realTree.node(atByteOffset: dotOffset + 1)
        while let node = current {
            switch node.type {
            case "field_access", "method_invocation", "method_reference":
                let object = node.type == "method_reference" ? node.namedChildren.first : node.child(byFieldName: "object")
                let name = node.type == "method_reference" ? node.namedChildren.last
                    : node.child(byFieldName: node.type == "field_access" ? "field" : "name")
                guard let object, let name, object.startByte != name.startByte else { return nil }
                if object.endByte <= dotOffset, name.startByte > dotOffset {
                    return object.hasError || object.isMissing ? nil : object.byteRange
                }
                current = node.parent
            case "ERROR", "block", "class_body", "program":
                return nil
            default:
                current = node.parent
            }
        }
        return nil
    }

    /// The synthetic wrapper is always `class __Synthetic__ { void __m__() { <receiver>; } }`; this
    /// walks that fixed shape to the expression inside the one expression-statement it produces.
    private static func outermostExpression(in root: SyntaxNode) -> SyntaxNode? {
        guard let classDecl = root.namedChildren.first(where: { $0.type == "class_declaration" }),
              let classBody = classDecl.child(byFieldName: "body"),
              let method = classBody.namedChildren.first(where: { $0.type == "method_declaration" }),
              let block = method.child(byFieldName: "body"),
              let statement = block.namedChildren.first(where: { $0.type == "expression_statement" }) else {
            return nil
        }
        return statement.namedChild(at: 0)
    }

    /// Types a standalone expression written in the file (e.g. a `var` initializer, the left-hand
    /// side of an assignment), with `locals` in scope. `nil` when it can't be parsed or typed.
    public static func typeOfExpression(
        _ expressionText: String, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> JavaReceiverInfo? {
        guard let syntheticTree = JavaSyntaxParser().parse("class __Synthetic__ { void __m__() { \(expressionText); } }"),
              let exprNode = outermostExpression(in: syntheticTree.rootNode) else {
            return nil
        }
        guard let result = await typed(exprNode, locals: locals, context: context, index: index), result.packageName == nil else { return nil }
        return JavaReceiverInfo(type: result.type, isTypeReference: result.isTypeReference)
    }

    /// Resolves the `var` locals in `locals` by typing their initializers (each against the locals
    /// declared before it), and implicitly typed lambda parameters from their call site. Other
    /// locals pass through unchanged.
    public static func resolvingVarLocals(
        _ locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> [JavaLocalVariable] {
        var result = locals
        for (position, local) in locals.enumerated() where local.lambdaOrigin != nil {
            if let typed = await typedIdentifier(local.name, locals: Array(locals[position...]), context: context, index: index), !typed.isTypeReference {
                result[position] = JavaLocalVariable(name: local.name, type: typed.type)
            }
        }
        for (position, local) in locals.enumerated() where local.isVarDeclaration {
            guard let initializer = local.initializerText else { continue }
            // `locals` is innermost-first, so everything after this one was declared before it.
            let visible = Array(result[(position + 1)...])
            if let info = await typeOfExpression(initializer, locals: visible, context: context, index: index), !info.isTypeReference {
                if local.isIterationVariable {
                    if let element = await iteratedElementType(of: info.type, context: context, index: index) {
                        result[position] = JavaLocalVariable(name: local.name, type: element)
                    }
                } else {
                    result[position] = JavaLocalVariable(name: local.name, type: info.type)
                }
            }
        }
        return result
    }

    // MARK: - Node typing

    /// A typed node result also says whether it's a *value* (an instance the `.` would offer
    /// instance members on) or a *type reference* (a bare class name like `Foo` used as a
    /// qualifier, where `.` should offer only static members). A dotted name that is neither a
    /// variable nor a type yet (`java.util` in `java.util.List`) is a package prefix.
    struct Typed {
        let type: JavaTypeRef
        let isTypeReference: Bool
        var packageName: String?

        static func value(_ type: JavaTypeRef) -> Typed { Typed(type: type, isTypeReference: false) }
        static func typeReference(_ type: JavaTypeRef) -> Typed { Typed(type: type, isTypeReference: true) }
        static func package(_ name: String) -> Typed {
            Typed(type: .unresolved(simpleName: name, arguments: []), isTypeReference: true, packageName: name)
        }
    }

    /// Types a node and resolves the result before returning it -- every recursive call goes
    /// through this wrapper (never `rawTyped` directly), so a type that's about to be used as a
    /// member-lookup receiver partway through a chain (e.g. the `bar` in `bar.value`, whose
    /// declared parameter type is `.unresolved("Bar")` until resolved) is never handed to
    /// ``JavaMemberLookup`` unresolved -- `JavaMemberLookup.members(of:...)` only understands
    /// `.classType`/`.array`, so an unresolved intermediate would silently produce zero members.
    static func typed(_ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        guard let raw = await rawTyped(node, locals: locals, context: context, index: index) else { return nil }
        if raw.packageName != nil { return raw }
        let resolvedType = await JavaTypeResolver.resolve(raw.type, context: context, index: index)
        if !raw.isTypeReference, case .typeVariable(let name) = resolvedType {
            // A value of type `T` has the members of `T`'s bound (`Object` when unbounded).
            let bound = context.typeParameterBounds[name] ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
            let resolvedBound = await JavaTypeResolver.resolve(bound, context: context, index: index)
            if case .typeVariable = resolvedBound { return Typed(type: resolvedType, isTypeReference: false) }
            return Typed(type: resolvedBound, isTypeReference: false)
        }
        return Typed(type: resolvedType, isTypeReference: raw.isTypeReference)
    }

    private static let stringType = JavaTypeRef.classType(qualifiedName: "java.lang.String", arguments: [], outer: nil)

    private static func rawTyped(_ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        switch node.type {
        case "parenthesized_expression":
            guard let inner = node.namedChild(at: 0) else { return nil }
            return await typed(inner, locals: locals, context: context, index: index)

        case "this":
            return implicitSelfType(context: context).map(Typed.value)

        case "super":
            guard let selfName = context.enclosingTypeQualifiedNames.first,
                  let superclass = await JavaMemberLookup.directSuperclass(of: selfName, context: context, index: index) else { return nil }
            return .value(superclass)

        case "identifier":
            return await typedIdentifier(node.text, locals: locals, context: context, index: index)

        case "field_access":
            return await typedFieldAccess(node, locals: locals, context: context, index: index)

        case "scoped_identifier", "scoped_type_identifier", "type_identifier", "generic_type":
            let type = JavaTypeNodeConverter.convert(node)
            return .typeReference(type)

        case "method_invocation":
            return await typedMethodInvocation(node, locals: locals, context: context, index: index)

        case "object_creation_expression":
            guard let typeNode = node.child(byFieldName: "type") else { return nil }
            return .value(await diamondResolved(JavaTypeNodeConverter.convert(typeNode), context: context, index: index))

        case "array_creation_expression":
            guard let typeNode = node.child(byFieldName: "type") else { return nil }
            var type = JavaTypeNodeConverter.convert(typeNode)
            let dimensionCount = node.namedChildren.filter { $0.type == "dimensions_expr" }.count
                + (node.namedChildren.first { $0.type == "dimensions" }.map { $0.text.filter { $0 == "[" }.count } ?? 0)
            for _ in 0..<max(1, dimensionCount) {
                type = .array(element: type)
            }
            return .value(type)

        case "array_access":
            guard let arrayNode = node.child(byFieldName: "array") else { return nil }
            guard let array = await typed(arrayNode, locals: locals, context: context, index: index) else { return nil }
            guard case .array(let element) = array.type else { return nil }
            return .value(element)

        case "cast_expression":
            guard let typeNode = node.child(byFieldName: "type") else { return nil }
            return .value(JavaTypeNodeConverter.convert(typeNode))

        case "class_literal":
            let target = node.namedChild(at: 0).map(JavaTypeNodeConverter.convert)
            let argument: [JavaTypeArgument] = target.map { [.type(boxed($0))] } ?? []
            return .value(.classType(qualifiedName: "java.lang.Class", arguments: argument, outer: nil))

        case "ternary_expression":
            if let consequence = node.child(byFieldName: "consequence"),
               let result = await typed(consequence, locals: locals, context: context, index: index), !isNullType(result.type) {
                return .value(result.type)
            }
            guard let alternative = node.child(byFieldName: "alternative") else { return nil }
            return await typed(alternative, locals: locals, context: context, index: index).map { .value($0.type) }

        case "binary_expression":
            return await typedBinary(node, locals: locals, context: context, index: index)

        case "instanceof_expression":
            return .value(.primitive(.boolean))

        case "unary_expression":
            guard let operand = node.child(byFieldName: "operand") else { return nil }
            let operatorText = node.child(byFieldName: "operator")?.text ?? node.children.first { !$0.isNamed }?.text ?? ""
            if operatorText == "!" { return .value(.primitive(.boolean)) }
            guard let typedOperand = await typed(operand, locals: locals, context: context, index: index) else { return nil }
            // Unary numeric promotion: byte/short/char operands become int.
            if case .primitive(let primitive) = typedOperand.type, [.byte, .short, .char].contains(primitive) {
                return .value(.primitive(.int))
            }
            return .value(typedOperand.type)

        case "update_expression":
            guard let operand = node.namedChild(at: 0) else { return nil }
            return await typed(operand, locals: locals, context: context, index: index).map { .value($0.type) }

        case "switch_expression":
            return await typedSwitchExpression(node, locals: locals, context: context, index: index)

        case "assignment_expression":
            guard let left = node.child(byFieldName: "left") else { return nil }
            return await typed(left, locals: locals, context: context, index: index).map { .value($0.type) }

        case "string_literal", "text_block":
            return .value(stringType)
        case "character_literal":
            return .value(.primitive(.char))
        case "decimal_integer_literal", "hex_integer_literal", "octal_integer_literal", "binary_integer_literal":
            return .value(.primitive(node.text.hasSuffix("L") || node.text.hasSuffix("l") ? .long : .int))
        case "decimal_floating_point_literal", "hex_floating_point_literal":
            return .value(.primitive(node.text.hasSuffix("f") || node.text.hasSuffix("F") ? .float : .double))
        case "true", "false":
            return .value(.primitive(.boolean))

        default:
            return nil
        }
    }

    /// A `switch` expression's type from its first arm that types: an arrow arm's expression, or
    /// the value of a `yield` in an arm's block. (Java takes the arms' common type; the first arm
    /// is the usual stand-in, like the ternary above.)
    private static func typedSwitchExpression(_ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        guard let body = node.child(byFieldName: "body") else { return nil }
        for arm in body.namedChildren {
            for value in armValues(arm) {
                if let result = await typed(value, locals: locals, context: context, index: index), !isNullType(result.type) {
                    return .value(result.type)
                }
            }
        }
        return nil
    }

    /// Value expressions of one switch arm: `case A -> expr;`, or `yield expr;` statements inside
    /// its block (not inside nested switches or lambdas).
    private static func armValues(_ arm: SyntaxNode) -> [SyntaxNode] {
        var values: [SyntaxNode] = []
        for child in arm.namedChildren {
            switch child.type {
            case "expression_statement":
                if let expression = child.namedChild(at: 0) { values.append(expression) }
            case "block":
                values += yieldValues(in: child)
            case "switch_label", "throw_statement":
                continue
            default:
                if arm.type == "switch_rule", child.type != "switch_label" { values.append(child) }
            }
        }
        if arm.type == "switch_block_statement_group" {
            values += yieldValues(in: arm)
        }
        return values
    }

    private static func yieldValues(in node: SyntaxNode) -> [SyntaxNode] {
        var values: [SyntaxNode] = []
        for child in node.namedChildren {
            if child.type == "yield_statement", let value = child.namedChild(at: 0) {
                values.append(value)
            } else if !["switch_expression", "lambda_expression", "class_body"].contains(child.type) {
                values += yieldValues(in: child)
            }
        }
        return values
    }

    private static func isNullType(_ type: JavaTypeRef) -> Bool {
        if case .unresolved("null", _) = type { return true }
        return false
    }

    private static func typedBinary(_ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        let operatorText = node.child(byFieldName: "operator")?.text ?? node.children.first { !$0.isNamed }?.text ?? ""
        switch operatorText {
        case "==", "!=", "<", ">", "<=", ">=", "&&", "||":
            return .value(.primitive(.boolean))
        default:
            break
        }
        guard let leftNode = node.child(byFieldName: "left"), let rightNode = node.child(byFieldName: "right") else { return nil }
        let left = await typed(leftNode, locals: locals, context: context, index: index)
        let right = await typed(rightNode, locals: locals, context: context, index: index)
        if operatorText == "+", left?.type == stringType || right?.type == stringType {
            return .value(stringType)
        }
        guard let left else { return right.map { .value($0.type) } }
        if case .primitive(let l) = left.type, case .primitive(let r)? = right?.type {
            let order: [JavaPrimitive] = [.byte, .short, .char, .int, .long, .float, .double]
            let widest = max(order.firstIndex(of: l) ?? 3, order.firstIndex(of: r) ?? 3, 3)
            return .value(l == .boolean ? .primitive(.boolean) : .primitive(order[widest]))
        }
        return .value(left.type)
    }

    /// `a.b`: a field of `a`, a nested type of type `a`, `Outer.this`, or -- when `a` is a package
    /// prefix -- the class `a.b` or the longer package `a.b`.
    private static func typedFieldAccess(_ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        guard let objectNode = node.child(byFieldName: "object"), let fieldNode = node.child(byFieldName: "field") else { return nil }
        guard let object = await typed(objectNode, locals: locals, context: context, index: index) else { return nil }
        if let packageName = object.packageName {
            let candidate = "\(packageName).\(fieldNode.text)"
            if await index.classStub(qualifiedName: candidate) != nil {
                return .typeReference(.classType(qualifiedName: candidate, arguments: [], outer: nil))
            }
            return .package(candidate)
        }
        if fieldNode.type == "this" {
            return .value(object.type)
        }
        let mode: JavaMemberLookupMode = object.isTypeReference ? .staticOnly : .instance
        let members = await JavaMemberLookup.members(of: object.type, mode: mode, context: context, index: index)
        if case .field(let field, _)? = members.first(where: {
            if case .field(let f, _) = $0 { return f.name == fieldNode.text }
            return false
        }) {
            return .value(field.type)
        }
        if object.isTypeReference, let outerName = object.type.erasedQualifiedName {
            let nested = "\(outerName).\(fieldNode.text)"
            if await index.classStub(qualifiedName: nested) != nil {
                return .typeReference(.classType(qualifiedName: nested, arguments: [], outer: nil))
            }
        }
        return nil
    }

    /// `foo` alone: a local/parameter first (shadows everything else, matching Java's own scoping),
    /// then an instance/static field of an enclosing type (implicit `this.foo`, including outer
    /// classes), then a statically imported field, then a type name, and finally -- when nothing
    /// matches -- the first segment of a package (`java` in `java.util.List`).
    private static func typedIdentifier(_ name: String, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        if let local = locals.first(where: { $0.name == name }) {
            if let origin = local.lambdaOrigin {
                let outer = locals.filter { $0.lambdaOrigin != origin }
                if let type = await lambdaParameterType(origin, locals: outer, context: context, index: index) {
                    return .value(type)
                }
            }
            if local.isVarDeclaration, let initializer = local.initializerText {
                let earlier = Array(locals.drop { $0.name != name }.dropFirst())
                guard let initialized = await typeOfExpression(initializer, locals: earlier, context: context, index: index) else { return nil }
                if local.isIterationVariable {
                    return await iteratedElementType(of: initialized.type, context: context, index: index).map(Typed.value)
                }
                return .value(initialized.type)
            }
            return .value(local.type)
        }
        for enclosing in context.enclosingTypeQualifiedNames {
            let selfType = JavaTypeRef.classType(qualifiedName: enclosing, arguments: [], outer: nil)
            let members = await JavaMemberLookup.members(of: selfType, mode: .instance, context: context, index: index)
            if case .field(let field, _)? = members.first(where: {
                if case .field(let f, _) = $0 { return f.name == name }
                return false
            }) {
                return .value(field.type)
            }
        }
        if let field = await staticallyImportedField(named: name, context: context, index: index) {
            return .value(field.type)
        }
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: name, arguments: []), context: context, index: index)
        guard case .unresolved = resolved else {
            return .typeReference(resolved)
        }
        if await !index.subpackages(of: name).isEmpty {
            return .package(name)
        }
        return nil
    }

    /// The element type an enhanced `for` gets from `iterated`: an array's element, or the type
    /// argument of the `Iterator` that `iterator()` returns (so `Map.entrySet()` and any custom
    /// `Iterable` work through their own type arguments).
    static func iteratedElementType(of iterated: JavaTypeRef, context: JavaResolutionContext, index: JavaIndex) async -> JavaTypeRef? {
        if case .array(let element) = iterated { return element }
        let iterator = await methods(named: "iterator", on: iterated, mode: .instance, context: context, index: index)
            .first { $0.parameters.isEmpty }
        guard let returnType = iterator?.returnType,
              case .classType(_, let arguments, _) = await JavaTypeResolver.resolve(returnType, context: context, index: index),
              let first = arguments.first else { return nil }
        switch first {
        case .type(let type), .wildcard(.extends(let type)?):
            return await JavaTypeResolver.resolve(type, context: context, index: index)
        case .wildcard:
            return .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
        }
    }

    private static func staticallyImportedField(named name: String, context: JavaResolutionContext, index: JavaIndex) async -> JavaFieldStub? {
        for member in await JavaStaticImports.members(context: context, index: index) {
            if case .field(let field, _) = member, field.name == name {
                return field
            }
        }
        return nil
    }

    /// `target` is the type the call's result is expected to have (the parameter it's passed to),
    /// used to bind type variables its arguments leave open: `collect(Collectors.toSet())`.
    private static func typedMethodInvocation(
        _ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex, target: JavaTypeRef? = nil
    ) async -> Typed? {
        let argumentNodes = node.child(byFieldName: "arguments")?.namedChildren ?? []
        let candidates = await invocationCandidates(node, locals: locals, context: context, index: index)
        guard !candidates.isEmpty else { return nil }

        // Lambdas and method references are typed after the overload is chosen, against the
        // functional interface of the parameter they land in.
        var argumentTypes: [JavaTypeRef?] = []
        for argument in argumentNodes {
            argumentTypes.append(isFunctionalArgument(argument) ? nil : await typed(argument, locals: locals, context: context, index: index)?.type)
        }
        guard let chosen = await resolveOverloads(candidates, argumentTypes: argumentTypes, context: context, index: index).first else { return nil }

        // Generic calls passed as arguments get the parameter type as their target.
        for (position, argument) in argumentNodes.enumerated() where argument.type == "method_invocation" {
            guard let parameterType = functionalParameterType(of: chosen, at: position),
                  let retyped = await typedMethodInvocation(argument, locals: locals, context: context, index: index, target: parameterType) else { continue }
            argumentTypes[position] = retyped.type
        }

        var extraBindings: [String: JavaTypeRef] = [:]
        let methodTypeVariables = Set(chosen.typeParameters.map(\.name))
        for (position, argument) in argumentNodes.enumerated() where isFunctionalArgument(argument) {
            guard let parameterType = functionalParameterType(of: chosen, at: position),
                  let signature = await functionalSignature(of: parameterType, context: context, index: index),
                  let result = await resultType(ofFunctional: argument, signature: signature, locals: locals, context: context, index: index) else { continue }
            bind(signature.returnType, to: result, names: methodTypeVariables, bindings: &extraBindings, fromTarget: false)
        }
        // `Collections.<User>emptyList()`: explicit type arguments bind the method's type
        // parameters in order and win over anything inferred.
        if let explicit = node.child(byFieldName: "type_arguments") {
            for (parameter, argument) in zip(chosen.typeParameters, explicit.namedChildren) {
                extraBindings[parameter.name] = await JavaTypeResolver.resolve(JavaTypeNodeConverter.convert(argument), context: context, index: index)
            }
        }
        if let target {
            bind(chosen.returnType, to: target, names: methodTypeVariables, bindings: &extraBindings, fromTarget: true)
        }
        let returnType = inferMethodTypeVariables(chosen, argumentTypes: argumentTypes, extraBindings: extraBindings)
        return .value(returnType)
    }

    /// The overloads a `method_invocation` node could call: members of its receiver, or for an
    /// unqualified call the innermost enclosing type that declares the name, then static imports.
    static func invocationCandidates(_ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> [JavaMethodStub] {
        guard let nameNode = node.child(byFieldName: "name") else { return [] }
        var candidates: [JavaMethodStub] = []
        if let objectNode = node.child(byFieldName: "object") {
            guard let receiver = await typed(objectNode, locals: locals, context: context, index: index), receiver.packageName == nil else { return [] }
            let mode: JavaMemberLookupMode = receiver.isTypeReference ? .staticOnly : .instance
            candidates = await methods(named: nameNode.text, on: receiver.type, mode: mode, context: context, index: index)
        } else {
            for enclosing in context.enclosingTypeQualifiedNames where candidates.isEmpty {
                let selfType = JavaTypeRef.classType(qualifiedName: enclosing, arguments: [], outer: nil)
                candidates = await methods(named: nameNode.text, on: selfType, mode: .instance, context: context, index: index)
            }
            if candidates.isEmpty {
                candidates = await JavaStaticImports.members(context: context, index: index).compactMap {
                    guard case .method(let method, _) = $0, method.name == nameNode.text else { return nil }
                    return method
                }
            }
        }
        return candidates
    }

    // MARK: - Lambdas and method references

    static func isFunctionalArgument(_ node: SyntaxNode) -> Bool {
        node.type == "lambda_expression" || node.type == "method_reference"
    }

    private static func functionalParameterType(of method: JavaMethodStub, at position: Int) -> JavaTypeRef? {
        if position < method.parameters.count {
            let type = method.parameters[position].type
            if position == method.parameters.count - 1, method.modifiers.contains(.varargs), case .array(let element) = type {
                return element
            }
            return type
        }
        if method.modifiers.contains(.varargs), case .array(let element)? = method.parameters.last?.type {
            return element
        }
        return nil
    }

    /// The single abstract method of a functional interface type, with the type's arguments
    /// substituted: `Function<? super StockSet, ? extends R>` → `(StockSet) -> R`.
    static func functionalSignature(of type: JavaTypeRef, context: JavaResolutionContext, index: JavaIndex) async -> (parameters: [JavaTypeRef], returnType: JavaTypeRef)? {
        guard case .classType = type else { return nil }
        let objectMethods: Set<String> = ["equals", "hashCode", "toString", "getClass", "notify", "notifyAll", "wait", "clone", "finalize"]
        for member in await JavaMemberLookup.members(of: type, mode: .instance, context: context, index: index) {
            guard case .method(let method, _) = member,
                  method.modifiers.contains(.abstractFlag), !method.modifiers.contains(.staticFlag),
                  !method.modifiers.contains(.defaultMethod), !objectMethods.contains(method.name) else { continue }
            return (method.parameters.map(\.type), method.returnType)
        }
        return nil
    }

    /// What a lambda or method reference produces when used as `signature`.
    private static func resultType(
        ofFunctional node: SyntaxNode, signature: (parameters: [JavaTypeRef], returnType: JavaTypeRef),
        locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> JavaTypeRef? {
        if node.type == "method_reference" {
            return await methodReferenceResult(node, arity: signature.parameters.count, locals: locals, context: context, index: index)
        }
        guard let body = node.child(byFieldName: "body") else { return nil }
        var scope = lambdaParameters(of: node).enumerated().map { position, name in
            JavaLocalVariable(name: name, type: position < signature.parameters.count ? signature.parameters[position] : .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil))
        }
        if let formal = node.child(byFieldName: "parameters"), formal.type == "formal_parameters" {
            scope = formal.namedChildren.filter { $0.type == "formal_parameter" }.compactMap { parameter in
                guard let typeNode = parameter.child(byFieldName: "type"), let nameNode = parameter.child(byFieldName: "name") else { return nil }
                return JavaLocalVariable(name: nameNode.text, type: JavaTypeNodeConverter.convert(typeNode))
            }
        }
        let bodyLocals = scope + locals
        if body.type == "block" {
            guard let returned = firstReturnExpression(in: body) else { return nil }
            return await typed(returned, locals: bodyLocals, context: context, index: index)?.type
        }
        return await typed(body, locals: bodyLocals, context: context, index: index)?.type
    }

    /// Names of a lambda's parameters: `x ->`, `(a, b) ->`, `(String s) ->`.
    static func lambdaParameters(of lambda: SyntaxNode) -> [String] {
        guard let parameters = lambda.child(byFieldName: "parameters") else { return [] }
        switch parameters.type {
        case "identifier":
            return [parameters.text]
        case "inferred_parameters":
            return parameters.namedChildren.filter { $0.type == "identifier" }.map(\.text)
        case "formal_parameters":
            return parameters.namedChildren.compactMap { $0.child(byFieldName: "name")?.text }
        default:
            return []
        }
    }

    private static func firstReturnExpression(in node: SyntaxNode) -> SyntaxNode? {
        for child in node.namedChildren {
            if child.type == "return_statement" { return child.namedChild(at: 0) }
            if child.type == "lambda_expression" || child.type == "class_body" { continue }
            if let nested = firstReturnExpression(in: child) { return nested }
        }
        return nil
    }

    /// `Type::method` (unbound receiver or static), `expr::method` (bound), `Type::new`.
    private static func methodReferenceResult(
        _ node: SyntaxNode, arity: Int, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> JavaTypeRef? {
        let named = node.namedChildren
        guard let objectNode = named.first,
              let object = await typed(objectNode, locals: locals, context: context, index: index), object.packageName == nil else { return nil }
        if node.text.hasSuffix("::new") || named.count < 2 {
            return object.type
        }
        let name = named[named.count - 1].text
        let candidates = await methods(named: name, on: object.type, mode: .instance, context: context, index: index)
        let chosen: JavaMethodStub?
        if object.isTypeReference {
            chosen = candidates.first { $0.modifiers.contains(.staticFlag) && $0.parameters.count == arity }
                ?? candidates.first { !$0.modifiers.contains(.staticFlag) && $0.parameters.count == arity - 1 }
        } else {
            chosen = candidates.first { $0.parameters.count == arity }
        }
        return (chosen ?? candidates.first).map { inferMethodTypeVariables($0, argumentTypes: []) }
    }

    /// Type of an implicitly typed lambda parameter, from the functional interface of its target:
    /// the parameter of the call it's passed to (`list.forEach(item -> item.|)` → the list's element
    /// type), or a declared/assigned/returned type (`Function<User, String> f = u -> u.|`).
    private static func lambdaParameterType(_ origin: JavaLambdaOrigin, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> JavaTypeRef? {
        for functional in await functionalTargets(of: origin.target, locals: locals, context: context, index: index) {
            guard let signature = await functionalSignature(of: functional, context: context, index: index),
                  origin.parameterIndex < signature.parameters.count else { continue }
            let type = signature.parameters[origin.parameterIndex]
            if case .typeVariable = type { continue }
            return await JavaTypeResolver.resolve(type, context: context, index: index)
        }
        return nil
    }

    /// The types `target` could convert an expression to, most likely first. A call argument gives
    /// one per overload that fits the argument count, with the method's type variables bound from
    /// the other arguments and from the call's own target (`comparing(u -> …)` passed to
    /// `sort(Comparator<? super User>)` binds `T` to `User`).
    static func functionalTargets(
        of target: JavaExpressionTarget, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> [JavaTypeRef] {
        switch target {
        case .declaredType(let type):
            return [await JavaTypeResolver.resolve(type, context: context, index: index)]
        case .assignedTo(let expressionText):
            guard let assigned = await typeOfExpression(expressionText, locals: locals, context: context, index: index) else { return [] }
            return [assigned.type]
        case .argument(let callText, let argumentIndex, let callTarget):
            guard let synthetic = JavaSyntaxParser().parse("class __Synthetic__ { void __m__() { \(callText); } }"),
                  let invocation = outermostExpression(in: synthetic.rootNode), invocation.type == "method_invocation" else { return [] }
            let argumentNodes = invocation.child(byFieldName: "arguments")?.namedChildren ?? []
            let candidates = await invocationCandidates(invocation, locals: locals, context: context, index: index)
            var argumentTypes: [JavaTypeRef?] = []
            for argument in argumentNodes {
                argumentTypes.append(isFunctionalArgument(argument) ? nil : await typed(argument, locals: locals, context: context, index: index)?.type)
            }
            let byArity = candidates.filter { $0.parameters.count == argumentNodes.count }
            var outerTargets: [JavaTypeRef] = []
            if let callTarget, candidates.contains(where: { !$0.typeParameters.isEmpty }) {
                outerTargets = await functionalTargets(of: callTarget, locals: locals, context: context, index: index)
            }
            var result: [JavaTypeRef] = []
            for method in (byArity.isEmpty ? candidates : byArity) {
                guard let parameterType = functionalParameterType(of: method, at: argumentIndex) else { continue }
                guard !method.typeParameters.isEmpty else {
                    result.append(parameterType)
                    continue
                }
                let names = Set(method.typeParameters.map(\.name))
                var bindings: [String: JavaTypeRef] = [:]
                for (position, argument) in argumentTypes.enumerated() where position != argumentIndex {
                    guard let argument, let parameter = functionalParameterType(of: method, at: position) else { continue }
                    bind(parameter, to: argument, names: names, bindings: &bindings)
                }
                if let outer = outerTargets.first {
                    bind(method.returnType, to: outer, names: names, bindings: &bindings, fromTarget: true)
                }
                result.append(substitute(parameterType, bindings))
            }
            return result
        }
    }

    static func methods(
        named name: String, on type: JavaTypeRef, mode: JavaMemberLookupMode, context: JavaResolutionContext, index: JavaIndex
    ) async -> [JavaMethodStub] {
        await JavaMemberLookup.members(of: type, mode: mode, context: context, index: index).compactMap { member in
            guard case .method(let method, _) = member, method.name == name else { return nil }
            return method
        }
    }

    /// Overload resolution in Java's three phases (JLS 15.12.2): candidates applicable by strict
    /// invocation (subtyping, primitive widening), else by loose invocation (boxing/unboxing too),
    /// else as variable-arity calls; then the most specific of those. Unknown argument types (a
    /// lambda, something that didn't type) are compatible with any reference parameter. Several
    /// results mean the call is ambiguous from what is known. When no candidate is applicable at
    /// all (an unindexed type, a half-typed call), falls back to ``bestOverloads(_:argumentTypes:)``.
    static func resolveOverloads(
        _ candidates: [JavaMethodStub], argumentTypes: [JavaTypeRef?], context: JavaResolutionContext, index: JavaIndex
    ) async -> [JavaMethodStub] {
        guard candidates.count > 1 else { return candidates }
        let assignability = JavaAssignability(index: index, context: context)
        var resolvedArguments: [JavaTypeRef?] = []
        for argument in argumentTypes {
            resolvedArguments.append(argument == nil ? nil : await assignability.resolve(argument!))
        }
        for phase in [OverloadPhase.strict, .loose, .variableArity] {
            var applicable: [(method: JavaMethodStub, parameters: [JavaTypeRef])] = []
            for method in candidates {
                guard let parameters = await applicableParameters(method, arguments: resolvedArguments, phase: phase, assignability: assignability) else { continue }
                applicable.append((method, parameters))
            }
            guard !applicable.isEmpty else { continue }
            if applicable.count == 1 { return [applicable[0].method] }
            var mostSpecific: [JavaMethodStub] = []
            for (position, candidate) in applicable.enumerated() {
                var beaten = false
                for (otherPosition, other) in applicable.enumerated() where otherPosition != position {
                    let otherFits = await isMoreSpecific(other.parameters, than: candidate.parameters, assignability: assignability)
                    let candidateFits = await isMoreSpecific(candidate.parameters, than: other.parameters, assignability: assignability)
                    if otherFits && !candidateFits { beaten = true; break }
                }
                if !beaten { mostSpecific.append(candidate.method) }
            }
            return mostSpecific.isEmpty ? applicable.map(\.method) : mostSpecific
        }
        return bestOverloads(candidates, argumentTypes: argumentTypes)
    }

    private enum OverloadPhase {
        case strict, loose, variableArity
    }

    /// The parameter types `method` takes the arguments at (varargs expanded in the variable-arity
    /// phase), or `nil` when it isn't applicable in `phase`.
    private static func applicableParameters(
        _ method: JavaMethodStub, arguments: [JavaTypeRef?], phase: OverloadPhase, assignability: JavaAssignability
    ) async -> [JavaTypeRef]? {
        var parameters: [JavaTypeRef] = []
        for parameter in method.parameters {
            parameters.append(await assignability.resolve(parameter.type))
        }
        if phase == .variableArity {
            guard method.modifiers.contains(.varargs), case .array(let element)? = parameters.last,
                  arguments.count >= parameters.count - 1 else { return nil }
            parameters = Array(parameters.dropLast()) + Array(repeating: element, count: arguments.count - (parameters.count - 1))
        } else {
            guard parameters.count == arguments.count else { return nil }
        }
        for (argument, parameter) in zip(arguments, parameters) {
            guard let argument else {
                if case .primitive = parameter { return nil }
                continue
            }
            guard await accepts(parameter, argument, allowBoxing: phase != .strict, assignability: assignability) else { return nil }
        }
        return parameters
    }

    private static func accepts(_ parameter: JavaTypeRef, _ argument: JavaTypeRef, allowBoxing: Bool, assignability: JavaAssignability) async -> Bool {
        let argumentIsPrimitive: Bool = { if case .primitive = argument { return true } else { return false } }()
        switch parameter {
        case .typeVariable, .wildcard, .unresolved:
            return allowBoxing || !argumentIsPrimitive
        default:
            break
        }
        if case .unresolved = argument { return true }
        let parameterIsPrimitive: Bool = { if case .primitive = parameter { return true } else { return false } }()
        if !allowBoxing, argumentIsPrimitive != parameterIsPrimitive { return false }
        return await assignability.isAssignable(argument, to: parameter)
    }

    /// `m1` is more specific than `m2` when each of its parameter types fits `m2`'s.
    private static func isMoreSpecific(_ lhs: [JavaTypeRef], than rhs: [JavaTypeRef], assignability: JavaAssignability) async -> Bool {
        for (l, r) in zip(lhs, rhs) {
            if case .typeVariable = r { continue }
            if case .typeVariable = l { return false }
            guard await assignability.isAssignable(l, to: r) else { return false }
        }
        return true
    }

    /// Arity first (exact, then varargs), then the candidate whose parameter types agree with the
    /// most argument types (erased names; unknown arguments count as agreeing).
    static func chooseOverload(_ candidates: [JavaMethodStub], argumentTypes: [JavaTypeRef?]) -> JavaMethodStub? {
        bestOverloads(candidates, argumentTypes: argumentTypes).first
    }

    /// Every candidate that ties for the best fit, in candidate order; one entry means the call
    /// binds to it, several mean the argument types could not tell the overloads apart.
    static func bestOverloads(_ candidates: [JavaMethodStub], argumentTypes: [JavaTypeRef?]) -> [JavaMethodStub] {
        let count = argumentTypes.count
        var applicable = candidates.filter { $0.parameters.count == count }
        if applicable.isEmpty {
            applicable = candidates.filter { $0.modifiers.contains(.varargs) && count >= max(0, $0.parameters.count - 1) }
        }
        if applicable.isEmpty {
            return candidates.first.map { [$0] } ?? []
        }
        guard applicable.count > 1 else { return applicable }
        func agreement(_ method: JavaMethodStub) -> Int {
            var score = 0
            for (position, argument) in argumentTypes.enumerated() {
                guard let argument else { score += 1; continue }
                let parameter = position < method.parameters.count ? method.parameters[position].type : method.parameters.last?.type
                guard let parameter else { continue }
                if roughlyAssignable(argument, to: parameter) { score += 2 }
                // An exact class match beats an `Object` or type-variable parameter that also accepts it.
                if case .classType(let argumentName, _, _) = argument, case .classType(let parameterName, _, _) = parameter,
                   argumentName == parameterName {
                    score += 1
                }
            }
            return score
        }
        let scores = applicable.map(agreement)
        let best = scores.max() ?? 0
        return zip(applicable, scores).filter { $0.1 == best }.map(\.0)
    }

    /// A cheap assignability check for overload choice: same erased class, primitive ⇄ box,
    /// anything to `Object`/a type variable.
    static func roughlyAssignable(_ argument: JavaTypeRef, to parameter: JavaTypeRef) -> Bool {
        switch parameter {
        case .typeVariable, .wildcard:
            return true
        case .array(let parameterElement):
            if case .array(let argumentElement) = argument { return roughlyAssignable(argumentElement, to: parameterElement) }
            return roughlyAssignable(argument, to: parameterElement) // varargs element
        case .primitive(let p):
            if case .primitive(let a) = argument { return a == p }
            return boxed(.primitive(p)).erasedQualifiedName == argument.erasedQualifiedName
        case .classType(let name, _, _):
            if name == "java.lang.Object" { return true }
            if case .primitive = argument { return boxed(argument).erasedQualifiedName == name }
            return argument.erasedQualifiedName == name
        default:
            return false
        }
    }

    /// Binds a generic method's own type variables from directly-typed arguments (`List.of(x)`,
    /// `Optional.of(x)`, `Arrays.asList(a, b)`) and substitutes them into the return type. Unbound
    /// variables fall back to their first bound, or `Object`.
    static func inferMethodTypeVariables(
        _ method: JavaMethodStub, argumentTypes: [JavaTypeRef?], extraBindings: [String: JavaTypeRef] = [:]
    ) -> JavaTypeRef {
        guard !method.typeParameters.isEmpty else { return method.returnType }
        let names = Set(method.typeParameters.map(\.name))
        var bindings = extraBindings
        for (position, argument) in argumentTypes.enumerated() {
            guard let argument else { continue }
            let isVarargsTail = method.modifiers.contains(.varargs) && position >= method.parameters.count - 1
            guard let parameter = position < method.parameters.count ? method.parameters[position].type : method.parameters.last?.type else { continue }
            var target = parameter
            if isVarargsTail, case .array(let element) = parameter, !isArray(argument) {
                target = element
            }
            bind(target, to: argument, names: names, bindings: &bindings)
        }
        for parameter in method.typeParameters where bindings[parameter.name] == nil {
            bindings[parameter.name] = parameter.bounds.first ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
        }
        return substitute(method.returnType, bindings)
    }

    private static func isArray(_ type: JavaTypeRef) -> Bool {
        if case .array = type { return true }
        return false
    }

    /// Structurally matches `parameter` against `argument`, recording what each of `names` stands
    /// for. With `fromTarget`, the "argument" is an expected type that may itself still contain
    /// unbound type variables; those are never recorded as bindings.
    private static func bind(
        _ parameter: JavaTypeRef, to argument: JavaTypeRef, names: Set<String>, bindings: inout [String: JavaTypeRef], fromTarget: Bool = false
    ) {
        if fromTarget, case .typeVariable = argument { return }
        switch parameter {
        case .typeVariable(let name) where names.contains(name) && bindings[name] == nil:
            bindings[name] = boxed(argument)
        case .unresolved(let name, []) where names.contains(name) && bindings[name] == nil:
            bindings[name] = boxed(argument)
        case .array(let element):
            if case .array(let argumentElement) = argument { bind(element, to: argumentElement, names: names, bindings: &bindings, fromTarget: fromTarget) }
        case .classType(_, let parameterArguments, _):
            guard case .classType(_, let argumentArguments, _) = argument else { return }
            for (p, a) in zip(parameterArguments, argumentArguments) {
                guard let at = argumentTypeValue(a) else { continue }
                switch p {
                case .type(let pt), .wildcard(.extends(let pt)?), .wildcard(.superBound(let pt)?):
                    bind(pt, to: at, names: names, bindings: &bindings, fromTarget: fromTarget)
                case .wildcard(nil):
                    break
                }
            }
        default:
            break
        }
    }

    private static func argumentTypeValue(_ argument: JavaTypeArgument) -> JavaTypeRef? {
        switch argument {
        case .type(let t), .wildcard(.extends(let t)?), .wildcard(.superBound(let t)?): return t
        case .wildcard(nil): return nil
        }
    }

    private static func substitute(_ type: JavaTypeRef, _ bindings: [String: JavaTypeRef]) -> JavaTypeRef {
        switch type {
        case .typeVariable(let name):
            return bindings[name] ?? type
        case .unresolved(let name, let arguments):
            if arguments.isEmpty, let bound = bindings[name] { return bound }
            return .unresolved(simpleName: name, arguments: arguments.map { substituteArgument($0, bindings) })
        case .array(let element):
            return .array(element: substitute(element, bindings))
        case .classType(let name, let arguments, let outer):
            return .classType(qualifiedName: name, arguments: arguments.map { substituteArgument($0, bindings) }, outer: outer)
        default:
            return type
        }
    }

    private static func substituteArgument(_ argument: JavaTypeArgument, _ bindings: [String: JavaTypeRef]) -> JavaTypeArgument {
        switch argument {
        case .type(let t):
            return .type(substitute(t, bindings))
        case .wildcard(.extends(let t)):
            return .wildcard(.extends(substitute(t, bindings)))
        case .wildcard(.superBound(let t)):
            return .wildcard(.superBound(substitute(t, bindings)))
        case .wildcard(nil):
            return argument
        }
    }

    /// The wrapper class for a primitive (`int` → `Integer`); other types pass through.
    static func boxed(_ type: JavaTypeRef) -> JavaTypeRef {
        guard case .primitive(let primitive) = type else { return type }
        let name: String
        switch primitive {
        case .boolean: name = "Boolean"
        case .byte: name = "Byte"
        case .char: name = "Character"
        case .short: name = "Short"
        case .int: name = "Integer"
        case .long: name = "Long"
        case .float: name = "Float"
        case .double: name = "Double"
        }
        return .classType(qualifiedName: "java.lang.\(name)", arguments: [], outer: nil)
    }

    /// `new ArrayList<>()` gets no arguments here; members then show their declared (generic) types.
    private static func diamondResolved(_ type: JavaTypeRef, context: JavaResolutionContext, index: JavaIndex) async -> JavaTypeRef {
        type
    }

    /// The type of an implicit/explicit `this`: the innermost enclosing type. Its own declared
    /// type parameters are intentionally left as an empty argument list here (not filled with
    /// type-variable placeholders) -- `JavaMemberLookup`'s substitution only fires when arguments
    /// are actually provided, and `this`'s members should keep their *declared* (still-generic)
    /// types, e.g. a field of type `T` stays `T`, which is exactly the "no substitution" case.
    private static func implicitSelfType(context: JavaResolutionContext) -> JavaTypeRef? {
        guard let enclosing = context.enclosingTypeQualifiedNames.first else { return nil }
        return .classType(qualifiedName: enclosing, arguments: [], outer: nil)
    }
}
