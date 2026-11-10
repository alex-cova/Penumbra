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
///    file's tree, via ``JavaSyntaxTree/visibleLocals(atByteOffset:)``, since the synthetic snippet obviously has none of its
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
    ///
    /// `bytes` is `source`'s UTF-8 when the caller already has it (a completion request does: it is
    /// the tree's own array); passing it spares copying the whole document to find a receiver.
    public static func receiverInfo(
        source: String, bytes knownBytes: [UInt8]? = nil, realTree: JavaSyntaxTree, dotOffset: Int,
        context: JavaResolutionContext, index: JavaIndex
    ) async -> JavaReceiverInfo? {
        let bytes = knownBytes ?? Array(source.utf8)
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
        let locals = realTree.visibleLocals(atByteOffset: dotOffset)
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

    /// Resolves the `var` locals in `locals` by typing their initializers (each against the other
    /// locals, as resolved so far), and implicitly typed lambda parameters from their call site.
    /// Other locals pass through unchanged.
    public static func resolvingVarLocals(
        _ locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> [JavaLocalVariable] {
        var result = locals
        for (position, local) in locals.enumerated() where local.lambdaOrigin != nil {
            if let typed = await typedIdentifier(local.name, locals: Array(locals[position...]), context: context, index: index), !typed.isTypeReference {
                result[position] = JavaLocalVariable(name: local.name, type: typed.type)
            }
        }
        // `locals` lists an inner block's variables before an outer block's, but the variables of one
        // block in source order, so a `var` can depend on one listed after it (`var b = a;` in an inner
        // block) or before it (`var a = f(); var b = a;`). Resolve in passes, each against every other
        // local as resolved so far, until a pass resolves nothing. A name is declared once per scope,
        // so seeing a later declaration cannot change what an initializer means in valid code.
        for _ in 0 ..< 3 {
            var progressed = false
            for (position, local) in locals.enumerated() where local.isVarDeclaration && result[position].isVarDeclaration {
                guard let initializer = local.initializerText else { continue }
                var visible = result
                visible.remove(at: position)
                guard let info = await typeOfExpression(initializer, locals: visible, context: context, index: index),
                      !info.isTypeReference else { continue }
                if local.isIterationVariable {
                    if let element = await iteratedElementType(of: info.type, context: context, index: index) {
                        result[position] = JavaLocalVariable(name: local.name, type: element)
                        progressed = true
                    }
                } else if let varType = JavaTypeSystem.inferredVarType(initializerType: info.type) {
                    result[position] = JavaLocalVariable(name: local.name, type: varType)
                    progressed = true
                }
            }
            if !progressed { break }
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
        /// Set when `type` is the bound standing in for a value of type variable `T`, so callers
        /// that want the parameter itself (Go to Type Declaration) can still reach it.
        var typeVariable: String?

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
            // `T extends A & B` has the members of both (JLS 4.9): keep the variable, and member
            // lookup unites its bounds. With one bound (or none) the value is typed as that bound.
            if (context.typeParameterBounds[name]?.count ?? 0) > 1 {
                return Typed(type: resolvedType, isTypeReference: false)
            }
            // A value of type `T` has the members of `T`'s only bound (`Object` when unbounded).
            let bound = context.typeParameterBounds[name]?.first ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
            let resolvedBound = await JavaTypeResolver.resolve(bound, context: context, index: index)
            if case .typeVariable = resolvedBound { return Typed(type: resolvedType, isTypeReference: false) }
            return Typed(type: resolvedBound, isTypeReference: false, typeVariable: name)
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
            // `new Foo() { … }` has the anonymous type, not `Foo` (JLS 15.9.5), when the caller can
            // resolve it; otherwise `Foo`, as before.
            if node.firstNamedChild(ofType: "class_body") != nil,
               let anonymous = await JavaAnonymousClass.stub(for: node, context: context, index: index) {
                return .value(.classType(qualifiedName: anonymous.qualifiedName, arguments: [], outer: nil))
            }
            return .value(await diamondResolved(
                JavaTypeNodeConverter.convert(typeNode), creation: node, typeNode: typeNode,
                locals: locals, context: context, index: index
            ))

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
            var arms: [JavaTypeRef] = []
            for field in ["consequence", "alternative"] {
                if let arm = node.child(byFieldName: field),
                   let result = await typed(arm, locals: locals, context: context, index: index) {
                    arms.append(result.type)
                }
            }
            return await conditionalType(of: arms, index: index).map { .value($0) }

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

    /// A `switch` expression's type from the values of all its arms: an arrow arm's expression, or
    /// the value of a `yield` in an arm's block, combined like the arms of a conditional.
    private static func typedSwitchExpression(_ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        guard let body = node.child(byFieldName: "body") else { return nil }
        var arms: [JavaTypeRef] = []
        for arm in body.namedChildren {
            for value in armValues(arm) {
                if let result = await typed(value, locals: locals, context: context, index: index) {
                    arms.append(result.type)
                }
            }
        }
        return await conditionalType(of: arms, index: index).map { .value($0) }
    }

    /// The type of a conditional or `switch` expression given the types of its arms (JLS 15.25):
    /// `null` arms give way to the others; numeric arms promote (`c ? 1 : 2.5` is `double`);
    /// boolean arms stay boolean; reference arms (primitives boxed) meet in their lub. An arm that
    /// does not type is left out, and nothing typed at all gives `nil`.
    static func conditionalType(of arms: [JavaTypeRef], index: JavaIndex) async -> JavaTypeRef? {
        let known = arms.filter { !isNullType($0) }
        guard let first = known.first else { return arms.first }
        let hadNull = known.count < arms.count
        if known.count == 1 { return hadNull ? boxed(first) : first }
        let unboxedArms = known.map(unboxed)
        if unboxedArms.allSatisfy({ if case .primitive(.boolean)? = $0 { return true } else { return false } }) {
            return .primitive(.boolean)
        }
        let numeric = unboxedArms.compactMap { arm -> JavaPrimitive? in
            if case .primitive(let primitive)? = arm, primitive != .boolean { return primitive }
            return nil
        }
        if numeric.count == known.count, !hadNull {
            if Set(numeric).count == 1 { return .primitive(numeric[0]) }
            let order: [JavaPrimitive] = [.byte, .short, .char, .int, .long, .float, .double]
            if Set(numeric).isSubset(of: [.byte, .short]) { return .primitive(.short) }
            let widest = numeric.map { order.firstIndex(of: $0) ?? 3 }.max() ?? 3
            return .primitive(order[max(widest, 3)])
        }
        return await JavaTypeSystem.lubKeepingArguments(of: known.map(boxed), index: index) ?? boxed(first)
    }

    /// The primitive a wrapper class unboxes to (`Integer` → `int`); other types pass through.
    private static func unboxed(_ type: JavaTypeRef) -> JavaTypeRef? {
        guard case .classType(let name, _, _) = type else { return type }
        let primitive: JavaPrimitive?
        switch name {
        case "java.lang.Boolean": primitive = .boolean
        case "java.lang.Byte": primitive = .byte
        case "java.lang.Character": primitive = .char
        case "java.lang.Short": primitive = .short
        case "java.lang.Integer": primitive = .int
        case "java.lang.Long": primitive = .long
        case "java.lang.Float": primitive = .float
        case "java.lang.Double": primitive = .double
        default: primitive = nil
        }
        return primitive.map { .primitive($0) } ?? type
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
        if await index.hasSubpackages(of: name) {
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
        guard let inference = await inferInvocation(
            node, locals: locals, context: context, index: index, target: target, callTarget: nil, excludingArgument: nil, limit: 1
        ).first else { return nil }
        let returnType = inferMethodTypeVariables(inference.method, argumentTypes: inference.argumentTypes, extraBindings: inference.bindings)
        return .value(withoutInferenceMarkers(returnType))
    }

    // MARK: - Invocation inference

    /// What inferring one call settled on: the chosen overload (its type parameters renamed apart,
    /// see ``renamedApart(_:)``), what each of its type variables stands for, and the types of the
    /// plain arguments. A variable that is not in `bindings` is still open.
    struct InvocationInference {
        let method: JavaMethodStub
        let bindings: [String: JavaTypeRef]
        let argumentTypes: [JavaTypeRef?]
    }

    /// How many lambda-parameter inferences are in progress on this task, each waiting on the
    /// enclosing call's (see ``functionalTargets(of:locals:context:index:keepingOpenVariables:)``).
    @TaskLocal private static var inferenceDepth = 0
    private static let maximumInferenceDepth = 8

    /// The marker that sets a method's type variables apart from the type variables in scope at
    /// the call. Bindings are keyed by name, so a callee `<T>` and the caller's own `<T>` were one
    /// variable: `build(() -> new ArrayList<T>(), (l, v) -> …)` inside `<T> void m()` bound the
    /// callee's `R` to a type that mentioned the caller's `T`, which the callee's `T` then read as
    /// its own open variable. `#` cannot appear in a Java identifier.
    private static let inferenceMarker = "#"

    static func isInferenceVariable(_ name: String) -> Bool { name.hasSuffix(inferenceMarker) }

    /// `method` with its own type parameters renamed to `T#`, in parameters, bounds and return type.
    private static func renamedApart(_ method: JavaMethodStub) -> JavaMethodStub {
        guard !method.typeParameters.isEmpty else { return method }
        var renames: [String: JavaTypeRef] = [:]
        for parameter in method.typeParameters { renames[parameter.name] = .typeVariable(name: parameter.name + inferenceMarker) }
        return JavaMethodStub(
            name: method.name,
            typeParameters: method.typeParameters.map {
                JavaTypeParameter(name: $0.name + inferenceMarker, bounds: $0.bounds.map { substitute($0, renames) })
            },
            parameters: method.parameters.map { JavaParameterStub(name: $0.name, type: substitute($0.type, renames)) },
            returnType: substitute(method.returnType, renames),
            thrownTypes: method.thrownTypes, modifiers: method.modifiers, isConstructor: method.isConstructor, javadoc: method.javadoc
        )
    }

    /// `type` with every `T#` read as the plain `T` again: what leaves the inference.
    static func withoutInferenceMarkers(_ type: JavaTypeRef) -> JavaTypeRef {
        switch type {
        case .typeVariable(let name) where isInferenceVariable(name):
            return .typeVariable(name: String(name.dropLast(inferenceMarker.count)))
        case .unresolved(let name, let arguments):
            return .unresolved(simpleName: name, arguments: arguments.map(withoutInferenceMarkers))
        case .array(let element):
            return .array(element: withoutInferenceMarkers(element))
        case .classType(let name, let arguments, let outer):
            return .classType(qualifiedName: name, arguments: arguments.map(withoutInferenceMarkers), outer: outer.map(withoutInferenceMarkers))
        case .wildcard(let bound):
            return .wildcard(bound: bound.map(withoutInferenceMarkers))
        default:
            return type
        }
    }

    private static func withoutInferenceMarkers(_ argument: JavaTypeArgument) -> JavaTypeArgument {
        switch argument {
        case .type(let type): return .type(withoutInferenceMarkers(type))
        case .wildcard(let bound): return .wildcard(bound.map(withoutInferenceMarkers))
        }
    }

    private static func withoutInferenceMarkers(_ bound: JavaWildcardBound) -> JavaWildcardBound {
        switch bound {
        case .extends(let type): return .extends(withoutInferenceMarkers(type))
        case .superBound(let type): return .superBound(withoutInferenceMarkers(type))
        }
    }

    /// Infers the call `node` for each overload that survives overload resolution (at most
    /// `limit`). Constraints are taken in javac's order (JLS 18.5): explicit type arguments, the
    /// call's own target, the plain arguments (several arguments for one variable meet in their
    /// lub), generic calls passed as arguments, and then the lambdas and method references: those
    /// whose parameter types are already known first, in argument order, each contributing its
    /// result (and, for an explicitly typed lambda or an unbound method reference, its parameter
    /// types) to the variables the rest still wait on. A lambda whose parameters depend on a
    /// variable nothing else settles is typed last, with that variable at its bound.
    ///
    /// `excludingArgument` leaves one argument out: asking for the type of that lambda's own
    /// parameter must not let the lambda (whose body holds the caret and is usually unfinished)
    /// constrain itself. `callTarget` is the call's target when it has none typed yet
    /// (`users.sort(Comparator.comparing(…))`), read only when a chosen overload is generic.
    private static func inferInvocation(
        _ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex,
        target: JavaTypeRef?, callTarget: JavaExpressionTarget?, excludingArgument excluded: Int?, limit: Int
    ) async -> [InvocationInference] {
        let argumentNodes = node.child(byFieldName: "arguments")?.namedChildren ?? []
        let candidates = await invocationCandidates(node, locals: locals, context: context, index: index)
        guard !candidates.isEmpty else { return [] }

        // Lambdas and method references are typed after the overload is chosen, against the
        // functional interface of the parameter they land in; until then only their shape is known.
        var argumentTypes: [JavaTypeRef?] = []
        for (position, argument) in argumentNodes.enumerated() {
            let deferredArgument = isFunctionalArgument(argument) || position == excluded
            argumentTypes.append(deferredArgument ? nil : await typed(argument, locals: locals, context: context, index: index)?.type)
        }
        // Shapes only matter when there is a choice to make; the asked-about lambda keeps its arity alone.
        let shapes: [FunctionalShape?] = candidates.count > 1
            ? argumentNodes.enumerated().map { functionalShape(of: $0.element, includingBody: $0.offset != excluded) }
            : []
        let chosen = await resolveOverloads(candidates, argumentTypes: argumentTypes, shapes: shapes, context: context, index: index)
        var results: [InvocationInference] = []
        for method in chosen.prefix(limit) {
            var outer = target
            if outer == nil, let callTarget, !method.typeParameters.isEmpty {
                outer = await functionalTargets(of: callTarget, locals: locals, context: context, index: index).first
            }
            results.append(await infer(
                renamedApart(method), argumentNodes: argumentNodes, argumentTypes: argumentTypes, node: node, target: outer,
                excluded: excluded, locals: locals, context: context, index: index
            ))
        }
        return results
    }

    private static func infer(
        _ chosen: JavaMethodStub, argumentNodes: [SyntaxNode], argumentTypes plainTypes: [JavaTypeRef?], node: SyntaxNode,
        target: JavaTypeRef?, excluded: Int?, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> InvocationInference {
        var argumentTypes = plainTypes
        var bindings: [String: JavaTypeRef] = [:]
        let methodTypeVariables = Set(chosen.typeParameters.map(\.name))
        // `Collections.<User>emptyList()`: explicit type arguments bind the method's type
        // parameters in order and win over anything inferred.
        if let explicit = node.child(byFieldName: "type_arguments") {
            for (parameter, argument) in zip(chosen.typeParameters, explicit.namedChildren) {
                bindings[parameter.name] = await JavaTypeResolver.resolve(JavaTypeNodeConverter.convert(argument), context: context, index: index)
            }
        }
        // A target reaches a type argument as an equality (`List<String> l = asList(…)`: `T = String`)
        // but a bare return variable only as an upper bound (`R <: List<String>` for
        // `<R> R build(Supplier<R>, …)`), and a variable resolves to its lower bounds, the
        // arguments and lambda results, before any upper bound (JLS 18.4). So a bare variable
        // takes the target after those, and still before an input is given its default.
        let returnsBareVariable: Bool = {
            switch chosen.returnType {
            case .typeVariable(let name), .unresolved(let name, []): return methodTypeVariables.contains(name)
            default: return false
            }
        }()
        if let target, !returnsBareVariable {
            bind(chosen.returnType, to: target, names: methodTypeVariables, bindings: &bindings, fromTarget: true, scope: context.typeParameterNames)
        }
        let isGenericCall = { (position: Int) in argumentNodes[position].type == "method_invocation" }
        let plainArguments = argumentTypes.enumerated().map { isGenericCall($0.offset) ? nil : $0.element }
        for (name, type) in await argumentBindings(of: chosen, argumentTypes: plainArguments, index: index) where bindings[name] == nil {
            bindings[name] = type
        }
        // Generic calls passed as arguments get the parameter type as their target, with what is
        // known so far substituted into it (`Collectors.toMap(Function.identity(), …)` passed to
        // `collect` already knows `T` is the stream's element type). A target that still mentions
        // a variable only a lambda can bind (`mapping(s -> s.trim(), toList())`: `toList()` needs
        // `U`) waits until the lambdas have been typed.
        var deferred: [Int] = []
        for (position, argument) in argumentNodes.enumerated() where argument.type == "method_invocation" && position != excluded {
            guard let parameterType = functionalParameterType(of: chosen, at: position) else { continue }
            let known = substitute(parameterType, bindings)
            if mentions(known, anyOf: methodTypeVariables) {
                deferred.append(position)
                argumentTypes[position] = nil
                continue
            }
            if let retyped = await typedMethodInvocation(argument, locals: locals, context: context, index: index, target: known) {
                argumentTypes[position] = retyped.type
            }
        }
        for (name, type) in await argumentBindings(of: chosen, argumentTypes: argumentTypes, index: index) where bindings[name] == nil {
            bindings[name] = type
        }

        var pending = argumentNodes.indices.filter { isFunctionalArgument(argumentNodes[$0]) && $0 != excluded }
        func settleLambdasWithKnownInputs() async {
            var progressed = true
            while progressed, !pending.isEmpty {
                progressed = false
                for position in pending {
                    if await applyFunctional(
                        argumentNodes[position], at: position, of: chosen, requireKnownInputs: true, bindings: &bindings,
                        locals: locals, context: context, index: index
                    ) {
                        pending.removeAll { $0 == position }
                        progressed = true
                    }
                }
            }
        }
        await settleLambdasWithKnownInputs()
        if let target, returnsBareVariable {
            bind(chosen.returnType, to: target, names: methodTypeVariables, bindings: &bindings, fromTarget: true, scope: context.typeParameterNames)
            await settleLambdasWithKnownInputs()
        }
        for position in pending {
            _ = await applyFunctional(
                argumentNodes[position], at: position, of: chosen, requireKnownInputs: false, bindings: &bindings,
                locals: locals, context: context, index: index
            )
        }

        for position in deferred {
            guard let parameterType = functionalParameterType(of: chosen, at: position),
                  let retyped = await typedMethodInvocation(
                      argumentNodes[position], locals: locals, context: context, index: index, target: substitute(parameterType, bindings)
                  ) else { continue }
            argumentTypes[position] = retyped.type
        }
        if !deferred.isEmpty {
            for (name, type) in await argumentBindings(of: chosen, argumentTypes: argumentTypes, index: index) where bindings[name] == nil {
                bindings[name] = type
            }
        }
        return InvocationInference(method: chosen, bindings: bindings, argumentTypes: argumentTypes)
    }

    /// Lets the lambda or method reference at `position` constrain the call's type variables.
    /// Returns `false`, changing nothing, when `requireKnownInputs` and the lambda's parameters
    /// (which it does not declare) still depend on a variable nothing has settled yet.
    private static func applyFunctional(
        _ argument: SyntaxNode, at position: Int, of method: JavaMethodStub, requireKnownInputs: Bool,
        bindings: inout [String: JavaTypeRef], locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> Bool {
        guard let declared = functionalParameterType(of: method, at: position) else { return true }
        let variables = Set(method.typeParameters.map(\.name))
        guard var signature = await functionalSignature(of: substitute(declared, bindings), context: context, index: index) else { return true }

        let isImplicitLambda: Bool = {
            guard argument.type == "lambda_expression", let parameters = argument.child(byFieldName: "parameters") else { return false }
            return parameters.type != "formal_parameters" && !lambdaParameters(of: argument).isEmpty
        }()
        let boundBefore = bindings.count
        // What the lambda's parameters are declared as: an explicitly typed lambda or an unbound
        // method reference tells the call what its inputs are, before they are needed.
        if argument.type == "lambda_expression", let formal = argument.child(byFieldName: "parameters"), formal.type == "formal_parameters" {
            let declaredTypes = formal.namedChildren.filter { $0.type == "formal_parameter" }.compactMap { $0.child(byFieldName: "type") }
            for (parameterIndex, typeNode) in declaredTypes.enumerated() where parameterIndex < signature.parameters.count {
                let written = await JavaTypeResolver.resolve(JavaTypeNodeConverter.convert(typeNode), context: context, index: index)
                bind(signature.parameters[parameterIndex], to: written, names: variables, bindings: &bindings)
            }
        } else if argument.type == "method_reference" {
            for (parameterIndex, type) in await methodReferenceInputs(argument, parameters: signature.parameters, locals: locals, context: context, index: index) {
                bind(signature.parameters[parameterIndex], to: type, names: variables, bindings: &bindings)
            }
        }
        // The signature was read before those constraints; read it again only if they added any.
        if bindings.count != boundBefore, let settled = await functionalSignature(of: substitute(declared, bindings), context: context, index: index) {
            signature = settled
        }

        var scopeSignature = signature
        if isImplicitLambda, signature.parameters.contains(where: { mentions($0, anyOf: variables) }) {
            if requireKnownInputs { return false }
            // The inputs nothing settled are resolved to their bounds before the body is typed
            // (JLS 18.5.2.2), so the body sees `Object` or the declared bound, not an open variable.
            var defaults: [String: JavaTypeRef] = [:]
            for parameter in method.typeParameters where bindings[parameter.name] == nil {
                defaults[parameter.name] = parameter.bounds.first.map { substitute($0, [parameter.name: objectType]) } ?? objectType
            }
            scopeSignature.parameters = signature.parameters.map { substitute($0, defaults) }
        }
        guard let result = await resultType(ofFunctional: argument, signature: scopeSignature, locals: locals, context: context, index: index) else { return true }
        var fromLambda: [String: JavaTypeRef] = [:]
        bind(signature.returnType, to: result, names: variables, bindings: &fromLambda, fromTarget: false)
        for (name, type) in fromLambda where bindings[name] == nil && !mentions(type, anyOf: variables) { bindings[name] = type }
        return true
    }

    private static let objectType = JavaTypeRef.classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)

    /// Parameter types of the functional interface that a method reference pins down by itself:
    /// `User::getName` takes a `User` first (when `User` is complete without type arguments), and
    /// a reference to the only method of that arity (`Integer::parseInt`) gives its parameters.
    private static func methodReferenceInputs(
        _ node: SyntaxNode, parameters: [JavaTypeRef], locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> [(Int, JavaTypeRef)] {
        let named = node.namedChildren
        guard named.count >= 2, !node.text.hasSuffix("::new"), let objectNode = named.first,
              let object = await typed(objectNode, locals: locals, context: context, index: index),
              object.packageName == nil, object.isTypeReference,
              case .classType(let className, let classArguments, _) = object.type else { return [] }
        let arity = parameters.count
        let candidates = await methods(named: named[named.count - 1].text, on: object.type, mode: .instance, context: context, index: index)
        let instance = candidates.filter { !$0.modifiers.contains(.staticFlag) && $0.parameters.count == arity - 1 }
        let statics = candidates.filter { $0.modifiers.contains(.staticFlag) && $0.parameters.count == arity }
        var inputs: [(Int, JavaTypeRef)] = []
        if statics.isEmpty, !instance.isEmpty, arity >= 1 {
            let isGeneric = !(await index.classStub(qualifiedName: className)?.typeParameters.isEmpty ?? true)
            if !classArguments.isEmpty || !isGeneric {
                inputs.append((0, object.type))
            }
            if instance.count == 1, instance[0].typeParameters.isEmpty {
                for (offset, parameter) in instance[0].parameters.enumerated() { inputs.append((offset + 1, parameter.type)) }
            }
        } else if instance.isEmpty, statics.count == 1, statics[0].typeParameters.isEmpty {
            for (offset, parameter) in statics[0].parameters.enumerated() { inputs.append((offset, parameter.type)) }
        }
        return inputs
    }

    /// Whether `type` mentions one of the type variables `names`.
    private static func mentions(_ type: JavaTypeRef, anyOf names: Set<String>) -> Bool {
        switch type {
        case .typeVariable(let name): return names.contains(name)
        case .unresolved(let name, let arguments):
            return (arguments.isEmpty && names.contains(name)) || arguments.contains { mentions($0, anyOf: names) }
        case .array(let element): return mentions(element, anyOf: names)
        case .classType(_, let arguments, let outer):
            return arguments.contains { mentions($0, anyOf: names) } || (outer.map { mentions($0, anyOf: names) } ?? false)
        case .wildcard(let bound): return bound.map { mentions($0, anyOf: names) } ?? false
        case .primitive, .void: return false
        }
    }

    private static func mentions(_ argument: JavaTypeArgument, anyOf names: Set<String>) -> Bool {
        switch argument {
        case .type(let type): return mentions(type, anyOf: names)
        case .wildcard(let bound): return bound.map { mentions($0, anyOf: names) } ?? false
        }
    }

    private static func mentions(_ bound: JavaWildcardBound, anyOf names: Set<String>) -> Bool {
        switch bound {
        case .extends(let type), .superBound(let type): return mentions(type, anyOf: names)
        }
    }

    /// The method type variables the plain (non-lambda) arguments bind. Several arguments for one
    /// variable (`List.of(1, 2.5)`) do not pick the first: the variable stands for the least upper
    /// bound of what they supply (JLS 18.5.2).
    private static func argumentBindings(
        of method: JavaMethodStub, argumentTypes: [JavaTypeRef?], index: JavaIndex
    ) async -> [String: JavaTypeRef] {
        guard !method.typeParameters.isEmpty else { return [:] }
        let names = Set(method.typeParameters.map(\.name))
        var candidates: [String: [JavaTypeRef]] = [:]
        for (position, argument) in argumentTypes.enumerated() {
            guard let argument, let target = parameterTarget(of: method, at: position, argument: argument) else { continue }
            var single: [String: JavaTypeRef] = [:]
            bind(target, to: argument, names: names, bindings: &single)
            for (name, type) in single { candidates[name, default: []].append(type) }
        }
        var result: [String: JavaTypeRef] = [:]
        for (name, types) in candidates {
            var distinct: [JavaTypeRef] = []
            for type in types where !distinct.contains(type) { distinct.append(type) }
            if distinct.count == 1 {
                result[name] = distinct[0]
            } else {
                result[name] = await JavaTypeSystem.lub(of: distinct, index: index) ?? distinct[0]
            }
        }
        return result
    }

    /// The parameter type an argument at `position` is matched against, with a varargs tail
    /// matched against the element type.
    private static func parameterTarget(of method: JavaMethodStub, at position: Int, argument: JavaTypeRef) -> JavaTypeRef? {
        let isVarargsTail = method.modifiers.contains(.varargs) && position >= method.parameters.count - 1
        guard let parameter = position < method.parameters.count ? method.parameters[position].type : method.parameters.last?.type else { return nil }
        if isVarargsTail, case .array(let element) = parameter, !isArray(argument) { return element }
        return parameter
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
            return await methodReferenceResult(node, parameters: signature.parameters, locals: locals, context: context, index: index)
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
    ///
    /// For an unbound receiver (`Map.Entry::getKey` as `Function<Entry<String, Integer>, R>`) the
    /// receiver is the functional interface's first parameter, viewed as `Type`: its type
    /// arguments are what make `getKey` return `String` instead of the declaration's `K`.
    private static func methodReferenceResult(
        _ node: SyntaxNode, parameters: [JavaTypeRef], locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> JavaTypeRef? {
        let arity = parameters.count
        let named = node.namedChildren
        guard let objectNode = named.first,
              let object = await typed(objectNode, locals: locals, context: context, index: index), object.packageName == nil else { return nil }
        if node.text.hasSuffix("::new") || named.count < 2 {
            return object.type
        }
        let name = named[named.count - 1].text
        var receiver = object.type
        if object.isTypeReference, arity >= 1, let referenced = object.type.erasedQualifiedName,
           let first = concreteType(of: parameters[0]),
           let viewed = await JavaMemberLookup.asSupertype(first, named: referenced, index: index) {
            receiver = viewed
        }
        let candidates = await methods(named: name, on: receiver, mode: .instance, context: context, index: index)
        let chosen: JavaMethodStub?
        if object.isTypeReference {
            chosen = candidates.first { $0.modifiers.contains(.staticFlag) && $0.parameters.count == arity }
                ?? candidates.first { !$0.modifiers.contains(.staticFlag) && $0.parameters.count == arity - 1 }
        } else {
            chosen = candidates.first { $0.parameters.count == arity }
        }
        return (chosen ?? candidates.first).map { inferMethodTypeVariables($0, argumentTypes: []) }
    }

    /// The class type a functional interface parameter stands for: `? super X` and `? extends X`
    /// read as `X`, which is what a method reference's receiver is.
    private static func concreteType(of type: JavaTypeRef) -> JavaTypeRef? {
        switch type {
        case .classType: return type
        case .wildcard(.extends(let bound)?), .wildcard(.superBound(let bound)?): return concreteType(of: bound)
        default: return nil
        }
    }

    /// Type of an implicitly typed lambda parameter, from the functional interface of its target:
    /// the parameter of the call it's passed to (`list.forEach(item -> item.|)` → the list's element
    /// type), or a declared/assigned/returned type (`Function<User, String> f = u -> u.|`).
    private static func lambdaParameterType(_ origin: JavaLambdaOrigin, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> JavaTypeRef? {
        // One answer per lambda parameter for the whole resolution it belongs to. A parameter used
        // in several sibling lambdas of nested calls is asked for once per use, and each ask runs
        // the enclosing call's inference, which types those same siblings: without this the work
        // doubles with every level of nesting. The memo lives for the outermost question only.
        guard let memo = lambdaParameterMemo else {
            return await $lambdaParameterMemo.withValue(LambdaParameterMemo()) {
                await lambdaParameterType(origin, locals: locals, context: context, index: index)
            }
        }
        let key = memoKey(for: origin, localCount: locals.count)
        if let known = memo.values[key] { return known }
        let result = await uncachedLambdaParameterType(origin, locals: locals, context: context, index: index)
        memo.values[key] = .some(result)
        return result
    }

    /// Built from the target's own strings: interpolating the enum itself goes through reflection,
    /// which cost more than the lookup it guards.
    private static func memoKey(for origin: JavaLambdaOrigin, localCount: Int) -> String {
        switch origin.target {
        case .argument(let callText, let argumentIndex, _):
            return "\(origin.parameterIndex)#\(localCount)#a\(argumentIndex)#\(callText)"
        case .assignedTo(let text):
            return "\(origin.parameterIndex)#\(localCount)#s#\(text)"
        case .declaredType(let type):
            return "\(origin.parameterIndex)#\(localCount)#d#\(type)"
        }
    }

    /// The answers already given during the current top-level lambda parameter question. Used
    /// sequentially by one task chain, never shared across tasks.
    private final class LambdaParameterMemo: @unchecked Sendable {
        var values: [String: JavaTypeRef?] = [:]
    }

    @TaskLocal private static var lambdaParameterMemo: LambdaParameterMemo?

    private static func uncachedLambdaParameterType(_ origin: JavaLambdaOrigin, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> JavaTypeRef? {
        for functional in await functionalTargets(of: origin.target, locals: locals, context: context, index: index, keepingOpenVariables: true) {
            guard let signature = await functionalSignature(of: functional, context: context, index: index),
                  origin.parameterIndex < signature.parameters.count else { continue }
            var type = signature.parameters[origin.parameterIndex]
            if case .typeVariable(let name) = type {
                // The call's own variable that nothing settled says nothing about the parameter; a
                // type variable in scope (`T` of the enclosing method) is a type like any other.
                if isInferenceVariable(name) || !context.typeParameterNames.contains(name) { continue }
            }
            type = withoutInferenceMarkers(type)
            return await JavaTypeResolver.resolve(type, context: context, index: index)
        }
        return nil
    }

    /// The types `target` could convert an expression to, most likely first. A call argument gives
    /// one per overload that fits the argument count, with the method's type variables bound from
    /// the other arguments and from the call's own target (`comparing(u -> …)` passed to
    /// `sort(Comparator<? super User>)` binds `T` to `User`).
    static func functionalTargets(
        of target: JavaExpressionTarget, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex,
        keepingOpenVariables: Bool = false
    ) async -> [JavaTypeRef] {
        switch target {
        case .declaredType(let type):
            return [await JavaTypeResolver.resolve(type, context: context, index: index)]
        case .assignedTo(let expressionText):
            guard let assigned = await typeOfExpression(expressionText, locals: locals, context: context, index: index) else { return [] }
            return [assigned.type]
        case .argument(let callText, let argumentIndex, let callTarget):
            // A lambda parameter used inside a sibling lambda asks its own call the same question,
            // so nested calls multiply. Past this depth the answer is "unknown" (the parameter
            // falls back to `Object`) instead of more work: real code nests a handful of levels.
            guard inferenceDepth < maximumInferenceDepth,
                  let synthetic = JavaSyntaxParser().parse("class __Synthetic__ { void __m__() { \(callText); } }"),
                  let invocation = outermostExpression(in: synthetic.rootNode), invocation.type == "method_invocation" else { return [] }
            // The parameter this argument lands in, with the call's type variables settled by
            // everything else in the call: the other arguments, the other lambdas' results and the
            // call's own target. The argument itself is left out; it is the one being asked about.
            let inferences = await $inferenceDepth.withValue(inferenceDepth + 1) {
                await inferInvocation(
                    invocation, locals: locals, context: context, index: index,
                    target: nil, callTarget: callTarget, excludingArgument: argumentIndex, limit: 3
                )
            }
            return inferences.compactMap { inference in
                guard let parameterType = functionalParameterType(of: inference.method, at: argumentIndex) else { return nil }
                let substituted = substitute(parameterType, inference.bindings)
                return keepingOpenVariables ? substituted : withoutInferenceMarkers(substituted)
            }
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
        _ candidates: [JavaMethodStub], argumentTypes: [JavaTypeRef?], shapes: [FunctionalShape?] = [],
        context: JavaResolutionContext, index: JavaIndex
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
                guard let parameters = await applicableParameters(
                    method, arguments: resolvedArguments, shapes: shapes, phase: phase, assignability: assignability, context: context, index: index
                ) else { continue }
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
        _ method: JavaMethodStub, arguments: [JavaTypeRef?], shapes: [FunctionalShape?], phase: OverloadPhase,
        assignability: JavaAssignability, context: JavaResolutionContext, index: JavaIndex
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
        for (position, (argument, parameter)) in zip(arguments, parameters).enumerated() {
            if position < shapes.count, let shape = shapes[position],
               !(await isPotentiallyCompatible(shape, with: parameter, context: context, index: index)) {
                return nil
            }
            guard let argument else {
                if case .primitive = parameter { return nil }
                continue
            }
            guard await accepts(parameter, argument, allowBoxing: phase != .strict, assignability: assignability) else { return nil }
        }
        return parameters
    }

    /// What overload resolution can know about a lambda or method reference before its target is
    /// chosen: how many parameters a lambda declares.
    enum FunctionalShape: Sendable, Equatable {
        case lambda(arity: Int, body: LambdaBody)
        case methodReference
    }

    /// Which functional interfaces a lambda body can serve (JLS 15.27.2): one whose method returns
    /// `void`, one that returns a value, or either. `unknown` for a body that is not finished.
    enum LambdaBody: Sendable, Equatable {
        case unknown, voidOnly, valueOnly, either
    }

    /// `includingBody: false` keeps only the arity: the lambda being asked about is unfinished by
    /// definition (its body holds the caret), and has to stay compatible with every overload.
    static func functionalShape(of node: SyntaxNode, includingBody: Bool = true) -> FunctionalShape? {
        switch node.type {
        case "lambda_expression":
            return .lambda(arity: lambdaParameters(of: node).count, body: includingBody ? lambdaBody(of: node) : .unknown)
        case "method_reference": return .methodReference
        default: return nil
        }
    }

    /// The body of a finished lambda, by JLS 15.27.2. An expression is a value, and also a statement
    /// when it is a call, an assignment, `++`/`--` or `new`; a block is a value when it returns one, and
    /// otherwise a statement unless it ends in `throw`. A body that has a syntax error, or holds the
    /// completion's dummy identifier, is `unknown`: it is not finished, and guessing would exclude
    /// the overload the developer is typing towards.
    static func lambdaBody(of lambda: SyntaxNode) -> LambdaBody {
        guard let body = lambda.child(byFieldName: "body"), !lambda.hasError, !containsDummyIdentifier(lambda) else { return .unknown }
        if body.type != "block" {
            switch body.type {
            case "method_invocation", "assignment_expression", "update_expression", "object_creation_expression": return .either
            default: return .valueOnly
            }
        }
        var returnsValue = false
        var returnsNothing = false
        var stack = [body]
        while let node = stack.popLast() {
            switch node.type {
            case "return_statement":
                if node.namedChildCount > 0 { returnsValue = true } else { returnsNothing = true }
            case "lambda_expression", "class_body":
                continue
            default:
                stack += node.namedChildren
            }
        }
        if returnsValue { return returnsNothing ? .unknown : .valueOnly }
        if returnsNothing { return .voidOnly }
        return body.namedChildren.last?.type == "throw_statement" ? .either : .voidOnly
    }

    private static func containsDummyIdentifier(_ node: SyntaxNode) -> Bool {
        let dummy = Array(JavaCompletionProvider.dummyIdentifier.utf8)
        let bytes = node.tree.sourceBytes
        let range = node.byteRange
        guard let first = dummy.first, range.count >= dummy.count else { return false }
        var index = range.lowerBound
        while index <= range.upperBound - dummy.count {
            if bytes[index] == first, bytes[index..<(index + dummy.count)].elementsEqual(dummy) { return true }
            index += 1
        }
        return false
    }

    /// Whether a lambda or method reference can be passed to a parameter of this type at all
    /// (JLS 15.12.2.1, "potentially compatible"): a functional interface whose method takes as many
    /// parameters as the lambda declares, or a type variable of the method. A class, an enum or an
    /// array never is, which is what keeps `Collector.of(supplier, accumulator, combiner, Seq::seq)`
    /// from binding `Seq::seq` to the varargs `Characteristics...` of the other overload. Bodies
    /// are not looked at: a lambda being typed has no `return` yet and cannot be told from `void`.
    private static func isPotentiallyCompatible(
        _ shape: FunctionalShape, with parameter: JavaTypeRef, context: JavaResolutionContext, index: JavaIndex
    ) async -> Bool {
        switch parameter {
        case .typeVariable, .unresolved, .wildcard:
            return true
        case .classType:
            guard let signature = await functionalSignature(of: parameter, context: context, index: index) else { return false }
            guard case .lambda(let arity, let body) = shape else { return true }
            guard signature.parameters.count == arity else { return false }
            switch body {
            case .unknown, .either: return true
            case .voidOnly: return signature.returnType == .void
            case .valueOnly: return signature.returnType != .void
            }
        default:
            return false
        }
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
        // `User[]` against `T[]`: a reference array fits an array of a type variable (no boxing of
        // elements, so `int[]` does not). Without this `Stream.of(users)` could only be `of(T)`.
        if case .array(let parameterElement) = parameter, case .array(let argumentElement) = argument {
            switch parameterElement {
            case .typeVariable, .unresolved, .wildcard:
                return await accepts(parameterElement, argumentElement, allowBoxing: false, assignability: assignability)
            default:
                break
            }
        }
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
        _ parameter: JavaTypeRef, to argument: JavaTypeRef, names: Set<String>, bindings: inout [String: JavaTypeRef], fromTarget: Bool = false,
        scope: Set<String>? = nil
    ) {
        // A target's open variables bind nothing. With the type variables in `scope` known, a
        // variable that is one of them is a real type (`T` of the method around the call), and only
        // the callee's own `T#` (or a name that is in no scope) stays open.
        if fromTarget, case .typeVariable(let name) = argument, isInferenceVariable(name) || !(scope?.contains(name) ?? false) { return }
        switch parameter {
        case .typeVariable(let name) where names.contains(name) && bindings[name] == nil:
            bindings[name] = boxed(argument)
        case .unresolved(let name, []) where names.contains(name) && bindings[name] == nil:
            bindings[name] = boxed(argument)
        case .array(let element):
            if case .array(let argumentElement) = argument { bind(element, to: argumentElement, names: names, bindings: &bindings, fromTarget: fromTarget, scope: scope) }
        case .classType(_, let parameterArguments, _):
            guard case .classType(_, let argumentArguments, _) = argument else { return }
            for (p, a) in zip(parameterArguments, argumentArguments) {
                guard let at = argumentTypeValue(a) else { continue }
                switch p {
                case .type(let pt), .wildcard(.extends(let pt)?), .wildcard(.superBound(let pt)?):
                    bind(pt, to: at, names: names, bindings: &bindings, fromTarget: fromTarget, scope: scope)
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

    /// `new ArrayList<>(List.of("a"))`: the class's own type parameters are bound from the
    /// constructor arguments (JLS 15.9.3, the part of diamond inference that needs no target).
    /// Anything the arguments leave open keeps the type raw (`new ArrayList<>()` stays
    /// `ArrayList`, so a declared target such as `List<String> l = new ArrayList<>()` is what
    /// supplies the arguments, as before).
    private static func diamondResolved(
        _ type: JavaTypeRef, creation: SyntaxNode, typeNode: SyntaxNode,
        locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex
    ) async -> JavaTypeRef {
        guard typeNode.type == "generic_type",
              let typeArguments = typeNode.namedChildren.first(where: { $0.type == "type_arguments" }),
              typeArguments.namedChildren.isEmpty else { return type }
        let argumentNodes = creation.child(byFieldName: "arguments")?.namedChildren ?? []
        guard !argumentNodes.isEmpty else { return type }
        let resolved = await JavaTypeResolver.resolve(type, context: context, index: index)
        guard case .classType(let qualifiedName, let existing, let outer) = resolved, existing.isEmpty,
              let stub = await index.classStub(qualifiedName: qualifiedName), !stub.typeParameters.isEmpty else { return type }
        let constructors = await JavaMemberLookup.constructors(of: resolved, context: context, index: index)
        guard !constructors.isEmpty else { return type }

        var argumentTypes: [JavaTypeRef?] = []
        for argument in argumentNodes {
            argumentTypes.append(isFunctionalArgument(argument) ? nil : await typed(argument, locals: locals, context: context, index: index)?.type)
        }
        // Only constructors that can take this many arguments compete.
        let arityMatches = constructors.filter {
            $0.parameters.count == argumentNodes.count
                || ($0.modifiers.contains(.varargs) && argumentNodes.count >= $0.parameters.count - 1)
        }
        // Choose on erased parameter types: `Collection<? extends E>` cannot be checked against
        // `List<String>` while `E` is still free. Binding below uses the original generic signature.
        func signature(_ parameters: [JavaParameterStub]) -> String {
            parameters.map { JavaTypeSystem.erasedName(of: $0.type) }.joined(separator: ",")
        }
        var originals: [String: JavaMethodStub] = [:]
        var erasedCandidates: [JavaMethodStub] = []
        for constructor in arityMatches {
            let erased = JavaMethodStub(
                name: constructor.name,
                typeParameters: constructor.typeParameters,
                parameters: constructor.parameters.map { JavaParameterStub(name: $0.name, type: JavaTypeSystem.erasure(of: $0.type)) },
                returnType: constructor.returnType,
                thrownTypes: constructor.thrownTypes,
                modifiers: constructor.modifiers,
                isConstructor: true,
                javadoc: constructor.javadoc
            )
            originals[signature(erased.parameters)] = constructor
            erasedCandidates.append(erased)
        }
        guard let picked = await resolveOverloads(erasedCandidates, argumentTypes: argumentTypes, context: context, index: index).first,
              let chosen = originals[signature(picked.parameters)] else { return type }

        let names = Set(stub.typeParameters.map(\.name))
        var bindings: [String: JavaTypeRef] = [:]
        for (position, argument) in argumentTypes.enumerated() {
            guard let argument, position < chosen.parameters.count else { continue }
            bind(chosen.parameters[position].type, to: argument, names: names, bindings: &bindings)
        }
        guard names.allSatisfy({ bindings[$0] != nil }) else { return type }
        return .classType(
            qualifiedName: qualifiedName,
            arguments: stub.typeParameters.compactMap { bindings[$0.name] }.map { .type($0) },
            outer: outer
        )
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
