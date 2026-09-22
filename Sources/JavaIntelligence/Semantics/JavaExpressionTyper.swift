import Foundation

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
/// Known simplifications (documented rather than silently wrong): method overload resolution is
/// arity-based only (no argument-type matching); `super.` is not yet handled; lambda expressions
/// used as call arguments aren't typed (irrelevant here -- only the outermost receiver is typed,
/// never a lambda's own body); a chain that bottoms out in something this can't type (an unindexed
/// class, a language feature not covered below) returns `nil` rather than guessing.
public enum JavaExpressionTyper {
    /// `source`/`realTree` are the live file being edited; `dotOffset` is the byte offset of the
    /// `.` (or other trigger character) itself. Returns the receiver's resolved type, or `nil` if
    /// there's no receiver, it can't be parsed, or it can't be typed.
    public static func typeOfReceiver(
        source: String, realTree: JavaSyntaxTree, dotOffset: Int, context: JavaResolutionContext, index: JavaIndex
    ) async -> JavaTypeRef? {
        let bytes = Array(source.utf8)
        guard let range = JavaReceiverScanner.receiverRange(in: bytes, dotOffset: dotOffset) else { return nil }
        let receiverText = String(decoding: bytes[range], as: UTF8.self)
        guard let syntheticTree = JavaSyntaxParser().parse("class __Synthetic__ { void __m__() { \(receiverText); } }"),
              let exprNode = outermostExpression(in: syntheticTree.rootNode) else {
            return nil
        }
        let locals = JavaLocalScope.locals(in: realTree, atByteOffset: dotOffset)
        return await typed(exprNode, locals: locals, context: context, index: index)?.type
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

    // MARK: - Node typing

    /// A typed node result also says whether it's a *value* (an instance the `.` would offer
    /// instance members on) or a *type reference* (a bare class name like `Foo` used as a
    /// qualifier, where `.` should offer only static members) -- only a bare `identifier` can be
    /// the latter; every other node kind always produces a value.
    private struct Typed {
        let type: JavaTypeRef
        let isTypeReference: Bool

        static func value(_ type: JavaTypeRef) -> Typed { Typed(type: type, isTypeReference: false) }
        static func typeReference(_ type: JavaTypeRef) -> Typed { Typed(type: type, isTypeReference: true) }
    }

    /// Types a node and resolves the result before returning it -- every recursive call goes
    /// through this wrapper (never `rawTyped` directly), so a type that's about to be used as a
    /// member-lookup receiver partway through a chain (e.g. the `bar` in `bar.value`, whose
    /// declared parameter type is `.unresolved("Bar")` until resolved) is never handed to
    /// ``JavaMemberLookup`` unresolved -- `JavaMemberLookup.members(of:...)` only understands
    /// `.classType`/`.array`, so an unresolved intermediate would silently produce zero members.
    private static func typed(_ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        guard let raw = await rawTyped(node, locals: locals, context: context, index: index) else { return nil }
        let resolvedType = await JavaTypeResolver.resolve(raw.type, context: context, index: index)
        return Typed(type: resolvedType, isTypeReference: raw.isTypeReference)
    }

    private static func rawTyped(_ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        switch node.type {
        case "parenthesized_expression":
            guard let inner = node.namedChild(at: 0) else { return nil }
            return await typed(inner, locals: locals, context: context, index: index)

        case "this":
            return implicitSelfType(context: context).map(Typed.value)

        case "identifier":
            return await typedIdentifier(node.text, locals: locals, context: context, index: index)

        case "field_access":
            guard let objectNode = node.child(byFieldName: "object"), let fieldNode = node.child(byFieldName: "field") else { return nil }
            guard let object = await typed(objectNode, locals: locals, context: context, index: index) else { return nil }
            let mode: JavaMemberLookupMode = object.isTypeReference ? .staticOnly : .instance
            let members = await JavaMemberLookup.members(of: object.type, mode: mode, context: context, index: index)
            guard case .field(let field, _) = members.first(where: { $0.name == fieldNode.text }) else { return nil }
            return .value(field.type)

        case "method_invocation":
            return await typedMethodInvocation(node, locals: locals, context: context, index: index)

        case "object_creation_expression":
            guard let typeNode = node.child(byFieldName: "type") else { return nil }
            return .value(JavaTypeNodeConverter.convert(typeNode))

        case "array_access":
            guard let arrayNode = node.child(byFieldName: "array") else { return nil }
            guard let array = await typed(arrayNode, locals: locals, context: context, index: index) else { return nil }
            guard case .array(let element) = array.type else { return nil }
            return .value(element)

        case "cast_expression":
            guard let typeNode = node.child(byFieldName: "type") else { return nil }
            return .value(JavaTypeNodeConverter.convert(typeNode))

        case "string_literal":
            return .value(.classType(qualifiedName: "java.lang.String", arguments: [], outer: nil))
        case "character_literal":
            return .value(.primitive(.char))
        case "decimal_integer_literal", "hex_integer_literal", "octal_integer_literal", "binary_integer_literal":
            return .value(.primitive(.int))
        case "decimal_floating_point_literal", "hex_floating_point_literal":
            return .value(.primitive(.double))
        case "true", "false":
            return .value(.primitive(.boolean))

        default:
            return nil
        }
    }

    /// `foo` alone: a local/parameter first (shadows everything else, matching Java's own scoping),
    /// then an instance/static field of an enclosing type (implicit `this.foo`), then -- if neither
    /// matches -- treated as a type name (`Foo.bar` where `Foo` is a class, not a variable). This
    /// mirrors how a real compiler disambiguates the same syntax.
    private static func typedIdentifier(_ name: String, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        if let local = locals.first(where: { $0.name == name }) {
            return .value(local.type)
        }
        if let selfType = implicitSelfType(context: context) {
            let members = await JavaMemberLookup.members(of: selfType, mode: .instance, context: context, index: index)
            if case .field(let field, _) = members.first(where: { $0.name == name }) {
                return .value(field.type)
            }
        }
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: name, arguments: []), context: context, index: index)
        guard case .unresolved = resolved else {
            return .typeReference(resolved)
        }
        return nil
    }

    private static func typedMethodInvocation(_ node: SyntaxNode, locals: [JavaLocalVariable], context: JavaResolutionContext, index: JavaIndex) async -> Typed? {
        guard let nameNode = node.child(byFieldName: "name") else { return nil }
        let argumentCount = node.child(byFieldName: "arguments")?.namedChildCount ?? 0

        let receiver: Typed?
        if let objectNode = node.child(byFieldName: "object") {
            receiver = await typed(objectNode, locals: locals, context: context, index: index)
        } else {
            // Unqualified call: implicit `this.name(...)`.
            receiver = implicitSelfType(context: context).map(Typed.value)
        }
        guard let receiver else { return nil }

        let mode: JavaMemberLookupMode = receiver.isTypeReference ? .staticOnly : .instance
        let members = await JavaMemberLookup.members(of: receiver.type, mode: mode, context: context, index: index)
        let candidates = members.compactMap { member -> JavaMethodStub? in
            guard case .method(let method, _) = member, method.name == nameNode.text else { return nil }
            return method
        }
        let exactArity = candidates.first { $0.parameters.count == argumentCount }
        let varargsMatch = candidates.first { $0.modifiers.contains(.varargs) && argumentCount >= max(0, $0.parameters.count - 1) }
        guard let chosen = exactArity ?? varargsMatch ?? candidates.first else { return nil }
        return .value(chosen.returnType)
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
