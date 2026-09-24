import Foundation

/// Resolving a reference to the stub it binds to (rather than to a location), for hover.
extension JavaNavigationSession {
    func resolveSymbols(_ reference: JavaReference) async -> [JavaResolvedSymbol] {
        switch reference {
        case .declaration:
            return await declarationSymbols()
        case .type(let token):
            return await typeSymbols(components: JavaReferenceClassifier.typeComponents(endingAt: token))
        case .constructor(let type, let argumentCount):
            guard let name = await typeQualifiedName(components: JavaReferenceClassifier.typeComponents(endingAt: type)) else {
                return []
            }
            return await constructorSymbols(of: name, argumentCount: argumentCount)
        case .explicitConstructor(let isSuper, let argumentCount):
            guard let owner = await constructorOwner(isSuper: isSuper), let name = owner.erasedQualifiedName else { return [] }
            return await constructorSymbols(of: name, argumentCount: argumentCount)
        case .methodCall(let invocation):
            return await methodCallTargets(invocation).map { .method($0.method, declaringClass: $0.declaringClass) }
        case .fieldAccess(let access):
            guard let target = await fieldAccessTarget(access) else { return [] }
            return [.field(target.field, declaringClass: target.declaringClass)]
        case .bareName(let token):
            return await bareNameSymbols(token.text)
        case .keywordThis:
            guard let name = context.enclosingTypeQualifiedNames.first else { return [] }
            return await stub(named: name).map { [.type($0)] } ?? []
        case .keywordSuper:
            guard let name = context.enclosingTypeQualifiedNames.first,
                  let superclass = await JavaMemberLookup.directSuperclass(of: name, context: context, index: index),
                  let qualified = superclass.erasedQualifiedName else { return [] }
            return await stub(named: qualified).map { [.type($0)] } ?? []
        case .import(let declaration, let clicked):
            return await importSymbols(declaration, clicked: clicked)
        }
    }

    // MARK: - Documentation

    /// The Javadoc of `symbol`. Source stubs carry it; class-file stubs (JARs, the JDK) do not, so
    /// their attached source is parsed for it. Attached sources only, never a decompiler.
    func documentation(for symbol: JavaResolvedSymbol) async -> String? {
        switch symbol {
        case .type(let stub):
            if let javadoc = stub.javadoc { return javadoc }
            return await attachedClass(matching: stub)?.javadoc
        case .method(let method, let declaringClass):
            if let javadoc = method.javadoc { return javadoc }
            guard let owner = await stub(named: declaringClass), let attached = await attachedClass(matching: owner) else { return nil }
            let keys = JavaTypeKeys.keys(of: method)
            return attached.methods.first {
                $0.name == method.name && $0.isConstructor == method.isConstructor && JavaTypeKeys.keys(of: $0) == keys
            }?.javadoc
        case .field(let field, let declaringClass):
            if let javadoc = field.javadoc { return javadoc }
            guard let owner = await stub(named: declaringClass), let attached = await attachedClass(matching: owner) else { return nil }
            return attached.fields.first { $0.name == field.name }?.javadoc
        case .local:
            return nil
        }
    }

    /// The same class as `stub`, parsed from its attached source file, when it has one.
    private func attachedClass(matching stub: JavaClassStub) async -> JavaClassStub? {
        if case .source = stub.origin { return nil }
        guard let file = await sourceFile(for: stub) else { return nil }
        let parsed = JavaSourceStubBuilder.build(tree: file.tree, url: file.url ?? URL(fileURLWithPath: "/attached/Source.java"))
        return parsed.classes.first { $0.qualifiedName == stub.qualifiedName }
    }

    // MARK: - Lookups

    private func stub(named qualifiedName: String) async -> JavaClassStub? {
        if let indexed = await index.classStub(qualifiedName: qualifiedName) { return indexed }
        return currentClasses.first { $0.qualifiedName == qualifiedName }
    }

    private func typeQualifiedName(components: [String]) async -> String? {
        guard let resolved = await resolveType(components: components),
              case .classType(let qualifiedName, _, _) = resolved else { return nil }
        return qualifiedName
    }

    private func typeSymbols(components: [String]) async -> [JavaResolvedSymbol] {
        guard let name = await typeQualifiedName(components: components), let found = await stub(named: name) else { return [] }
        return [.type(found)]
    }

    func constructorSymbols(of qualifiedName: String, argumentCount: Int) async -> [JavaResolvedSymbol] {
        let type = JavaTypeRef.classType(qualifiedName: qualifiedName, arguments: [], outer: nil)
        let declared = await JavaMemberLookup.constructors(of: type, context: context, index: index)
        if declared.isEmpty {
            return await stub(named: qualifiedName).map { [.type($0)] } ?? []
        }
        let targets = declared.map { MethodTarget(declaringClass: qualifiedName, method: $0) }
        return choose(primary: targets, secondary: [], argumentCount: argumentCount)
            .map { .method($0.method, declaringClass: $0.declaringClass) }
    }

    private func bareNameSymbols(_ name: String) async -> [JavaResolvedSymbol] {
        if let range = JavaDeclarationLocator.localDeclarationRange(name: name, in: tree, atByteOffset: byteOffset) {
            return [.local(name: name, declaration: declarationLine(containing: range.lowerBound))]
        }
        if let enclosing = context.enclosingTypeQualifiedNames.first {
            let type = JavaTypeRef.classType(qualifiedName: enclosing, arguments: [], outer: nil)
            if let target = await fieldTarget(named: name, on: type, mode: .instance) {
                return [.field(target.field, declaringClass: target.declaringClass)]
            }
        }
        let single = singleStaticImportTypes(member: name)
        let staticTypes = single.isEmpty ? context.imports.filter { $0.isStatic && $0.isOnDemand }.map(\.qualifiedName) : single
        for typeName in staticTypes {
            let type = JavaTypeRef.classType(qualifiedName: typeName, arguments: [], outer: nil)
            if let target = await fieldTarget(named: name, on: type, mode: .staticOnly) {
                return [.field(target.field, declaringClass: target.declaringClass)]
            }
        }
        return await typeSymbols(components: [name])
    }

    private func importSymbols(_ declaration: SyntaxNode, clicked: SyntaxNode) async -> [JavaResolvedSymbol] {
        let isStatic = declaration.children.contains { $0.type == "static" }
        let isOnDemand = declaration.namedChildren.contains { $0.type == "asterisk" }
        guard let path = declaration.namedChildren.first(where: { $0.type == "scoped_identifier" || $0.type == "identifier" }) else {
            return []
        }
        let parts = JavaReferenceClassifier.pathComponents(path)
        guard let clickedIndex = parts.firstIndex(where: { $0.range == clicked.byteRange }) else { return [] }
        let prefix = parts[...clickedIndex].map(\.name)
        if isStatic, !isOnDemand, clickedIndex == parts.count - 1, prefix.count >= 2 {
            let member = prefix[prefix.count - 1]
            let type = JavaTypeRef.classType(qualifiedName: prefix.dropLast().joined(separator: "."), arguments: [], outer: nil)
            let methods = await allMethods(named: member, on: type, mode: .staticOnly)
            if !methods.isEmpty { return methods.map { .method($0.method, declaringClass: $0.declaringClass) } }
            if let target = await fieldTarget(named: member, on: type, mode: .staticOnly) {
                return [.field(target.field, declaringClass: target.declaringClass)]
            }
            return []
        }
        return await stub(named: prefix.joined(separator: ".")).map { [.type($0)] } ?? []
    }

    /// A declaration name under the caret: the type, method or field it declares. Locals and
    /// parameters are skipped, since the declaration is already what the caret is on.
    private func declarationSymbols() async -> [JavaResolvedSymbol] {
        let leaf = tree.node(atByteOffset: byteOffset)
        guard let declaration = leaf.parent, let owner = context.enclosingTypeQualifiedNames.first else { return [] }
        let ownerStub = currentClasses.first { $0.qualifiedName == owner }
        let indexedOwner = await index.classStub(qualifiedName: owner)
        guard let stub = ownerStub ?? indexedOwner else { return [] }
        switch declaration.type {
        case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration":
            guard declaration.child(byFieldName: "name")?.byteRange == leaf.byteRange else { return [] }
            return [.type(stub)]
        case "method_declaration", "constructor_declaration":
            guard declaration.child(byFieldName: "name")?.byteRange == leaf.byteRange else { return [] }
            let arity = declaration.child(byFieldName: "parameters")?.namedChildCount ?? 0
            let isConstructor = declaration.type == "constructor_declaration"
            return stub.methods
                .filter { $0.isConstructor == isConstructor && $0.parameters.count == arity && (isConstructor || $0.name == leaf.text) }
                .map { .method($0, declaringClass: owner) }
        case "variable_declarator":
            guard declaration.parent?.type == "field_declaration",
                  let field = stub.fields.first(where: { $0.name == leaf.text }) else { return [] }
            return [.field(field, declaringClass: owner)]
        default:
            return []
        }
    }

    /// The source line holding `byteOffset`, trimmed, for showing a local's declaration.
    private func declarationLine(containing byteOffset: Int) -> String {
        let bytes = Array(source.utf8)
        var start = min(byteOffset, bytes.count)
        while start > 0, bytes[start - 1] != 10 { start -= 1 }
        var end = min(byteOffset, bytes.count)
        while end < bytes.count, bytes[end] != 10 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
