import EditorIntelligence
import Foundation

/// Go to Type Declaration for Java: from a variable, field, parameter, method call or any other
/// expression, jump to the declaration of its type. Generic types resolve to their outer class
/// (`List<User> users` → `List`), and an element type comes from substitution
/// (`users.get(0)` → `User`). A type reference, `this` and `super` go where Go to Definition goes.
enum JavaGoToTypeDefinition {
    static func resolve(
        source: String,
        fileURL: URL?,
        utf16Offset: Int,
        index: JavaIndex,
        jdkHome: URL?,
        cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)?,
        decompile: JavaDecompileGate
    ) async -> [JavaDefinitionHit] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: source)
        guard let token = JavaReferenceClassifier.nameToken(tree.node(atByteOffset: byteOffset), byteOffset: byteOffset),
              let reference = JavaReferenceClassifier.classify(token: token) else { return [] }
        let session = JavaNavigationSession(
            source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset,
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: openBuffer, decompile: decompile
        )
        return await session.typeDefinitionHits(reference, token: token)
    }
}

extension JavaNavigationSession {
    func typeDefinitionHits(_ reference: JavaReference, token: SyntaxNode) async -> [JavaDefinitionHit] {
        switch reference {
        case .declaration:
            return await declaredTypeHits(of: token)
        case .type(let node):
            return await typeHits(components: JavaReferenceClassifier.typeComponents(endingAt: node))
        case .constructor(let type, _):
            return await typeHits(components: JavaReferenceClassifier.typeComponents(endingAt: type))
        case .explicitConstructor(let isSuper, _):
            guard let owner = await constructorOwner(isSuper: isSuper) else { return [] }
            return await typeHits(of: owner)
        case .keywordThis, .keywordSuper, .import:
            return await resolve(reference)
        case .methodCall(let node), .fieldAccess(let node), .bareName(let node):
            return await expressionTypeHits(node)
        }
    }

    /// The type of the expression `node` (a call, field access or name), where it appears.
    private func expressionTypeHits(_ node: SyntaxNode) async -> [JavaDefinitionHit] {
        let locals = await scopeLocals(atByteOffset: byteOffset)
        guard let typed = await JavaExpressionTyper.typed(node, locals: locals, context: context, index: index),
              typed.packageName == nil else { return [] }
        // A value of type `T` is typed as `T`'s bound for member lookup; the type declaration is
        // the parameter itself when the current file declares it.
        if let name = typed.typeVariable {
            let parameter = await typeHits(of: .typeVariable(name: name))
            if !parameter.isEmpty { return parameter }
        }
        return await typeHits(of: typed.type)
    }

    private func scopeLocals(atByteOffset offset: Int) async -> [JavaLocalVariable] {
        await JavaExpressionTyper.resolvingVarLocals(
            JavaLocalScope.locals(in: tree, atByteOffset: offset), context: context, index: index
        )
    }

    /// The type a declaration's name gives its symbol: a variable's declared type, a method's
    /// return type, an enum constant's or constructor's class. A type declares itself.
    private func declaredTypeHits(of token: SyntaxNode) async -> [JavaDefinitionHit] {
        guard let parent = token.parent else { return [] }
        switch parent.type {
        case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration",
             "annotation_type_declaration", "type_parameter":
            return [hit(text: source, url: fileURL, byteRange: token.byteRange, displayName: token.text)]
        case "constructor_declaration", "enum_constant":
            guard let owner = context.enclosingTypeQualifiedNames.first else { return [] }
            return await typeHits(qualifiedName: owner)
        case "method_declaration":
            return await typeNodeHits(parent.child(byFieldName: "type"))
        case "variable_declarator":
            guard let declaration = parent.parent else { return [] }
            return await variableTypeHits(name: token.text, typeNode: declaration.child(byFieldName: "type"),
                                          scopeOffset: declaration.endByte)
        case "formal_parameter", "enhanced_for_statement", "resource":
            let scope = parent.child(byFieldName: "body")?.startByte ?? parent.endByte
            return await variableTypeHits(name: token.text, typeNode: parent.child(byFieldName: "type"),
                                          scopeOffset: scope)
        case "catch_formal_parameter":
            let caught = parent.firstNamedChild(ofType: "catch_type")?.namedChild(at: 0)
            return await typeNodeHits(caught)
        case "lambda_expression":
            let scope = parent.child(byFieldName: "body")?.startByte ?? parent.endByte
            return await variableTypeHits(name: token.text, typeNode: nil, scopeOffset: scope)
        default:
            return []
        }
    }

    /// A variable written with a type uses it; `var` and implicitly typed lambda parameters take
    /// the type the local scope infers.
    private func variableTypeHits(name: String, typeNode: SyntaxNode?, scopeOffset: Int) async -> [JavaDefinitionHit] {
        if let typeNode, typeNode.text != "var" {
            return await typeNodeHits(typeNode)
        }
        let locals = await scopeLocals(atByteOffset: scopeOffset)
        guard let local = locals.first(where: { $0.name == name }) else { return [] }
        return await typeHits(of: local.type)
    }

    private func typeNodeHits(_ node: SyntaxNode?) async -> [JavaDefinitionHit] {
        guard let node else { return [] }
        let components = JavaReferenceClassifier.pathComponents(node)
        guard !components.isEmpty else { return [] }
        return await typeHits(components: components.map(\.name))
    }

    /// The declaration of `type`: its class, an array's element class, a type variable's parameter.
    func typeHits(of type: JavaTypeRef) async -> [JavaDefinitionHit] {
        switch type {
        case .classType(let qualifiedName, _, _):
            return await typeHits(qualifiedName: qualifiedName)
        case .array(let element):
            return await typeHits(of: element)
        case .typeVariable(let name):
            guard let range = JavaDeclarationLocator.typeParameterRange(name: name, in: tree, atByteOffset: byteOffset) else {
                return []
            }
            return [hit(text: source, url: fileURL, byteRange: range, displayName: name)]
        case .unresolved(let simpleName, _):
            return await typeHits(components: [simpleName])
        case .primitive, .void, .wildcard:
            return []
        }
    }
}
