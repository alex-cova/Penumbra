import EditorIntelligence
import Foundation

struct JavaDefinitionHit: Equatable, Sendable {
    var url: URL?
    var range: EditorIntelligence.TextRange
    var displayName: String
}

/// Resolves the Java symbol at a caret to the declaration name that should be selected.
enum JavaGoToDefinition {
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
        guard let reference = JavaReferenceClassifier.classify(in: tree, atByteOffset: byteOffset) else { return [] }
        if case .declaration = reference { return [] }

        let session = JavaNavigationSession(
            source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset,
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: openBuffer, decompile: decompile
        )
        return await session.resolve(reference)
    }
}

struct MethodTarget {
    let declaringClass: String
    let method: JavaMethodStub
}

struct FieldTarget {
    let declaringClass: String
    let field: JavaFieldStub
}

struct JavaNavigationSession {
    let source: String
    let fileURL: URL?
    let tree: JavaSyntaxTree
    let byteOffset: Int
    let index: JavaIndex
    let jdkHome: URL?
    let cacheRoot: URL
    let openBuffer: (@Sendable (URL) async -> String?)?
    let decompile: JavaDecompileGate
    let context: JavaResolutionContext
    let currentClasses: [JavaClassStub]

    init(
        source: String, fileURL: URL?, tree: JavaSyntaxTree, byteOffset: Int,
        index: JavaIndex, jdkHome: URL?, cacheRoot: URL, openBuffer: (@Sendable (URL) async -> String?)?,
        decompile: JavaDecompileGate
    ) {
        let file = JavaSourceStubBuilder.build(tree: tree, url: fileURL ?? URL(fileURLWithPath: "/unsaved/Navigation.java"))
        self.init(
            source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset, fileStubs: file,
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: openBuffer, decompile: decompile
        )
    }

    /// - Parameter fileStubs: the stubs of `tree`, built once by a caller that resolves many
    ///   offsets in the same file (one session per offset, one stub build per file).
    init(
        source: String, fileURL: URL?, tree: JavaSyntaxTree, byteOffset: Int, fileStubs file: JavaSourceFileStubs,
        index: JavaIndex, jdkHome: URL?, cacheRoot: URL, openBuffer: (@Sendable (URL) async -> String?)?,
        decompile: JavaDecompileGate
    ) {
        self.source = source
        self.fileURL = fileURL
        self.tree = tree
        self.byteOffset = byteOffset
        self.index = index
        self.jdkHome = jdkHome
        self.cacheRoot = cacheRoot
        self.openBuffer = openBuffer
        self.decompile = decompile
        let enclosing = JavaCompletionProvider.enclosingTypeContext(in: tree, atByteOffset: byteOffset)
        let qualified = enclosing.qualifiedNames.map { name in
            file.packageName.isEmpty ? name : "\(file.packageName).\(name)"
        }
        self.currentClasses = file.classes
        self.context = JavaResolutionContext(
            packageName: file.packageName,
            imports: file.imports,
            enclosingTypeQualifiedNames: qualified,
            typeParameterNames: enclosing.typeParameterNames.union(Self.methodTypeParameters(in: tree, atByteOffset: byteOffset)),
            typeParameterBounds: JavaCompletionProvider.typeParameterBounds(in: tree, atByteOffset: byteOffset)
        )
    }

    func resolve(_ reference: JavaReference) async -> [JavaDefinitionHit] {
        switch reference {
        case .declaration:
            return []
        case .type(let token):
            return await typeHits(components: JavaReferenceClassifier.typeComponents(endingAt: token))
        case .constructor(let token, let argumentCount):
            return await constructorHits(
                components: JavaReferenceClassifier.typeComponents(endingAt: token), argumentCount: argumentCount
            )
        case .explicitConstructor(let isSuper, let argumentCount):
            guard let owner = await constructorOwner(isSuper: isSuper) else { return [] }
            return await constructorHits(type: owner, argumentCount: argumentCount)
        case .methodCall(let invocation):
            return await methodCallHits(invocation)
        case .fieldAccess(let access):
            return await fieldAccessHits(access)
        case .bareName(let token):
            return await bareNameHits(token.text)
        case .keywordThis:
            guard let name = context.enclosingTypeQualifiedNames.first else { return [] }
            return await typeHits(qualifiedName: name)
        case .keywordSuper:
            guard let name = context.enclosingTypeQualifiedNames.first,
                  let superclass = await JavaMemberLookup.directSuperclass(of: name, context: context, index: index),
                  let qualified = superclass.erasedQualifiedName else { return [] }
            return await typeHits(qualifiedName: qualified)
        case .import(let declaration, let clicked):
            return await importHits(declaration, clicked: clicked)
        }
    }

    // MARK: - References

    func typeHits(components: [String]) async -> [JavaDefinitionHit] {
        guard let resolved = await resolveType(components: components) else { return [] }
        switch resolved {
        case .typeVariable(let name):
            guard let range = JavaDeclarationLocator.typeParameterRange(name: name, in: tree, atByteOffset: byteOffset) else {
                return []
            }
            return [hit(text: source, url: fileURL, byteRange: range, displayName: name)]
        case .classType(let qualifiedName, _, _):
            return await typeHits(qualifiedName: qualifiedName)
        default:
            return []
        }
    }

    func typeHits(qualifiedName: String) async -> [JavaDefinitionHit] {
        let display = String(qualifiedName.split(separator: ".").last ?? Substring(qualifiedName))
        if let stub = await index.classStub(qualifiedName: qualifiedName), let file = await sourceFile(for: stub),
           let range = JavaDeclarationLocator.typeName(
               qualifiedName: qualifiedName, relaxedSimpleName: file.relaxedSimpleName, in: file.tree
           ) {
            return [hit(text: file.text, url: file.url, byteRange: range, displayName: display)]
        }
        if let range = JavaDeclarationLocator.typeName(qualifiedName: qualifiedName, in: tree) {
            return [hit(text: source, url: fileURL, byteRange: range, displayName: display)]
        }
        return []
    }

    func constructorHits(components: [String], argumentCount: Int) async -> [JavaDefinitionHit] {
        guard let resolved = await resolveType(components: components),
              case .classType(let qualifiedName, _, _) = resolved else { return [] }
        return await constructorHits(type: .classType(qualifiedName: qualifiedName, arguments: [], outer: nil), argumentCount: argumentCount)
    }

    func constructorHits(type: JavaTypeRef, argumentCount: Int) async -> [JavaDefinitionHit] {
        guard case .classType(let qualifiedName, _, _) = type else { return [] }
        let declared = await JavaMemberLookup.constructors(of: type, context: context, index: index)
        if declared.isEmpty {
            return await typeHits(qualifiedName: qualifiedName)
        }
        let targets = declared.map { MethodTarget(declaringClass: qualifiedName, method: $0) }
        let chosen = choose(primary: targets, secondary: [], argumentCount: argumentCount)
        let hits = await methodHits(chosen)
        return hits.isEmpty ? await typeHits(qualifiedName: qualifiedName) : hits
    }

    func constructorOwner(isSuper: Bool) async -> JavaTypeRef? {
        guard let enclosing = context.enclosingTypeQualifiedNames.first else { return nil }
        if !isSuper {
            return .classType(qualifiedName: enclosing, arguments: [], outer: nil)
        }
        return await JavaMemberLookup.directSuperclass(of: enclosing, context: context, index: index)
    }

    func methodCallHits(_ invocation: SyntaxNode) async -> [JavaDefinitionHit] {
        await methodHits(methodCallTargets(invocation))
    }

    /// The declarations a method call can bind to, narrowed by argument count.
    func methodCallTargets(_ invocation: SyntaxNode) async -> [MethodTarget] {
        await methodCallResolution(invocation).targets
    }

    /// `receiverKnown` is false when the call's receiver expression could not be typed, so an
    /// empty `targets` means "unknown" rather than "no such method".
    func methodCallResolution(_ invocation: SyntaxNode) async -> (targets: [MethodTarget], receiverKnown: Bool) {
        guard let nameNode = invocation.child(byFieldName: "name") else { return ([], true) }
        let argumentCount = invocation.child(byFieldName: "arguments")?.namedChildCount ?? 0
        guard let receiver = await receiverInfo(of: invocation, nameNode: nameNode) else {
            let imported = await staticImportMethods(named: nameNode.text)
            return (choose(primary: [], secondary: imported, argumentCount: argumentCount), false)
        }
        return (await methodCallTargets(invocation, receiver: receiver, nameNode: nameNode, argumentCount: argumentCount), true)
    }

    private func methodCallTargets(
        _ invocation: SyntaxNode, receiver: JavaReceiverInfo, nameNode: SyntaxNode, argumentCount: Int
    ) async -> [MethodTarget] {
        let mode: JavaMemberLookupMode = receiver.isTypeReference ? .staticOnly : .instance
        var primary = await allMethods(named: nameNode.text, on: receiver.type, mode: mode)
        if primary.isEmpty, invocation.child(byFieldName: "object") == nil {
            // An unqualified call may name a method of an enclosing class.
            for outer in context.enclosingTypeQualifiedNames.dropFirst() where primary.isEmpty {
                let outerType = JavaTypeRef.classType(qualifiedName: outer, arguments: [], outer: nil)
                primary = await allMethods(named: nameNode.text, on: outerType, mode: .instance)
            }
        }
        let secondary: [MethodTarget]
        if invocation.child(byFieldName: "object") == nil {
            secondary = await staticImportMethods(named: nameNode.text)
        } else {
            secondary = []
        }
        return choose(primary: primary, secondary: secondary, argumentCount: argumentCount)
    }

    func fieldAccessHits(_ access: SyntaxNode) async -> [JavaDefinitionHit] {
        guard let target = await fieldAccessTarget(access) else { return [] }
        return await fieldHits(of: target)
    }

    /// The field a `receiver.name` expression binds to, with the class that declares it.
    func fieldAccessTarget(_ access: SyntaxNode) async -> FieldTarget? {
        guard let fieldNode = access.child(byFieldName: "field") else { return nil }
        if access.child(byFieldName: "object")?.type == "super" {
            guard let enclosing = context.enclosingTypeQualifiedNames.first,
                  let superclass = await JavaMemberLookup.directSuperclass(of: enclosing, context: context, index: index) else {
                return nil
            }
            return await fieldTarget(named: fieldNode.text, on: superclass, mode: .instance)
        }
        guard let dot = dotOffset(before: fieldNode),
              let receiver = await JavaExpressionTyper.receiverInfo(
                source: source, realTree: tree, dotOffset: dot, context: context, index: index
              ) else { return nil }
        let mode: JavaMemberLookupMode = receiver.isTypeReference ? .staticOnly : .instance
        return await fieldTarget(named: fieldNode.text, on: receiver.type, mode: mode)
    }

    func bareNameHits(_ name: String) async -> [JavaDefinitionHit] {
        if let range = JavaDeclarationLocator.localDeclarationRange(name: name, in: tree, atByteOffset: byteOffset) {
            return [hit(text: source, url: fileURL, byteRange: range, displayName: name)]
        }
        for enclosing in context.enclosingTypeQualifiedNames {
            let type = JavaTypeRef.classType(qualifiedName: enclosing, arguments: [], outer: nil)
            let fields = await fieldHits(named: name, on: type, mode: .instance)
            if !fields.isEmpty { return fields }
        }
        let imported = await staticImportFieldHits(name)
        if !imported.isEmpty { return imported }
        return await typeHits(components: [name])
    }

    func importHits(_ declaration: SyntaxNode, clicked: SyntaxNode) async -> [JavaDefinitionHit] {
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
            let typeName = prefix.dropLast().joined(separator: ".")
            let type = JavaTypeRef.classType(qualifiedName: typeName, arguments: [], outer: nil)
            let methods = await methodHits(await allMethods(named: member, on: type, mode: .staticOnly))
            if !methods.isEmpty { return methods }
            return await fieldHits(named: member, on: type, mode: .staticOnly)
        }
        return await typeHits(qualifiedName: prefix.joined(separator: "."))
    }

    // MARK: - Members

    func receiverInfo(of invocation: SyntaxNode, nameNode: SyntaxNode) async -> JavaReceiverInfo? {
        if let object = invocation.child(byFieldName: "object"), object.type == "super" {
            guard let enclosing = context.enclosingTypeQualifiedNames.first,
                  let superclass = await JavaMemberLookup.directSuperclass(of: enclosing, context: context, index: index) else {
                return nil
            }
            return JavaReceiverInfo(type: superclass, isTypeReference: false)
        }
        if invocation.child(byFieldName: "object") == nil {
            guard let enclosing = context.enclosingTypeQualifiedNames.first else { return nil }
            return JavaReceiverInfo(
                type: .classType(qualifiedName: enclosing, arguments: [], outer: nil), isTypeReference: false
            )
        }
        guard let dot = dotOffset(before: nameNode) else { return nil }
        return await JavaExpressionTyper.receiverInfo(
            source: source, realTree: tree, dotOffset: dot, context: context, index: index
        )
    }

    func allMethods(named name: String, on type: JavaTypeRef, mode: JavaMemberLookupMode) async -> [MethodTarget] {
        let members = await JavaMemberLookup.members(of: type, mode: mode, context: context, index: index)
        return members.compactMap { member in
            guard case .method(let method, let declaringClass) = member, method.name == name else { return nil }
            return MethodTarget(declaringClass: declaringClass, method: method)
        }
    }

    func staticImportMethods(named name: String) async -> [MethodTarget] {
        var targets: [MethodTarget] = []
        for typeName in singleStaticImportTypes(member: name) {
            let type = JavaTypeRef.classType(qualifiedName: typeName, arguments: [], outer: nil)
            targets.append(contentsOf: await allMethods(named: name, on: type, mode: .staticOnly))
        }
        if !targets.isEmpty { return targets }
        for typeName in context.imports.filter({ $0.isStatic && $0.isOnDemand }).map(\.qualifiedName) {
            let type = JavaTypeRef.classType(qualifiedName: typeName, arguments: [], outer: nil)
            targets.append(contentsOf: await allMethods(named: name, on: type, mode: .staticOnly))
        }
        return targets
    }

    func fieldHits(named name: String, on type: JavaTypeRef, mode: JavaMemberLookupMode) async -> [JavaDefinitionHit] {
        guard let target = await fieldTarget(named: name, on: type, mode: mode) else { return [] }
        return await fieldHits(of: target)
    }

    func fieldTarget(named name: String, on type: JavaTypeRef, mode: JavaMemberLookupMode) async -> FieldTarget? {
        let members = await JavaMemberLookup.members(of: type, mode: mode, context: context, index: index)
        for member in members {
            if case .field(let field, let declaringClass) = member, field.name == name {
                return FieldTarget(declaringClass: declaringClass, field: field)
            }
        }
        return nil
    }

    func fieldHits(of target: FieldTarget) async -> [JavaDefinitionHit] {
        let name = target.field.name
        let declaringClass = target.declaringClass
        return await memberHits(declaringClass: declaringClass, displayName: name) { tree, relaxedSimpleName in
            JavaDeclarationLocator.fieldRanges(
                declaringClass: declaringClass, name: name, relaxedSimpleName: relaxedSimpleName, in: tree
            )
        }
    }

    func staticImportFieldHits(_ name: String) async -> [JavaDefinitionHit] {
        var hits: [JavaDefinitionHit] = []
        let single = singleStaticImportTypes(member: name)
        let types = single.isEmpty
            ? context.imports.filter { $0.isStatic && $0.isOnDemand }.map(\.qualifiedName)
            : single
        for typeName in types {
            let type = JavaTypeRef.classType(qualifiedName: typeName, arguments: [], outer: nil)
            hits.append(contentsOf: await fieldHits(named: name, on: type, mode: .staticOnly))
        }
        return dedupe(hits)
    }

    func singleStaticImportTypes(member: String) -> [String] {
        context.imports.compactMap { declaration in
            guard declaration.isStatic, !declaration.isOnDemand else { return nil }
            let parts = declaration.qualifiedName.split(separator: ".").map(String.init)
            guard parts.count >= 2, parts.last == member else { return nil }
            return parts.dropLast().joined(separator: ".")
        }
    }

    /// - Parameter qualifiedOwner: label each hit `Owner.method(...)`, for lists whose entries sit
    ///   in different classes (implementations).
    func methodHits(_ targets: [MethodTarget], qualifiedOwner: Bool = false) async -> [JavaDefinitionHit] {
        var hits: [JavaDefinitionHit] = []
        for target in targets {
            let display = qualifiedOwner
                ? "\(target.declaringClass.split(separator: ".").last.map(String.init) ?? target.declaringClass).\(methodDisplayName(target))"
                : methodDisplayName(target)
            let found = await memberHits(declaringClass: target.declaringClass, displayName: display) { tree, relaxedSimpleName in
                JavaDeclarationLocator.methodRanges(
                    declaringClass: target.declaringClass,
                    name: target.method.name,
                    parameterKeys: JavaTypeKeys.keys(of: target.method),
                    isConstructor: target.method.isConstructor,
                    relaxedSimpleName: relaxedSimpleName,
                    in: tree
                )
            }
            hits.append(contentsOf: found)
        }
        return dedupe(hits)
    }

    func methodDisplayName(_ target: MethodTarget) -> String {
        if target.method.isConstructor {
            let simple = String(target.declaringClass.split(separator: ".").last ?? Substring(target.declaringClass))
            return simple + target.method.parameterListDisplay
        }
        return target.method.name + target.method.parameterListDisplay
    }

    func choose(primary: [MethodTarget], secondary: [MethodTarget], argumentCount: Int) -> [MethodTarget] {
        func exact(_ targets: [MethodTarget]) -> [MethodTarget] {
            targets.filter { $0.method.parameters.count == argumentCount }
        }
        func varargs(_ targets: [MethodTarget]) -> [MethodTarget] {
            targets.filter { target in
                target.method.modifiers.contains(.varargs)
                    && argumentCount >= max(0, target.method.parameters.count - 1)
            }
        }
        if !exact(primary).isEmpty { return exact(primary) }
        if !exact(secondary).isEmpty { return exact(secondary) }
        if !varargs(primary).isEmpty { return varargs(primary) }
        if !varargs(secondary).isEmpty { return varargs(secondary) }
        if !primary.isEmpty { return primary }
        return secondary
    }

    // MARK: - Source files

    func memberHits(
        declaringClass: String, displayName: String, ranges: (JavaSyntaxTree, String?) -> [Range<Int>]
    ) async -> [JavaDefinitionHit] {
        guard let stub = await index.classStub(qualifiedName: declaringClass), let file = await sourceFile(for: stub) else {
            return []
        }
        return ranges(file.tree, file.relaxedSimpleName).map { range in
            hit(text: file.text, url: file.url, byteRange: range, displayName: displayName)
        }
    }

    func sourceFile(
        for stub: JavaClassStub
    ) async -> (url: URL?, text: String, tree: JavaSyntaxTree, relaxedSimpleName: String?)? {
        let top = await topLevel(stub)
        switch top.origin {
        case .source(let url, _):
            if JavaNavigationText.sameFile(url, fileURL) {
                return (fileURL, source, tree, nil)
            }
            if let text = await load(url), let parsed = JavaSyntaxParser().parse(text) {
                return (url, text, parsed, nil)
            }
            if currentClasses.contains(where: { $0.qualifiedName == stub.qualifiedName }) {
                return (fileURL, source, tree, nil)
            }
            return nil
        case .jdkModule(let module):
            if let extracted = JavaAttachedSources.extract(
                jdkHome: jdkHome, module: module, binaryJar: nil, topLevel: top, cacheRoot: cacheRoot
            ), let parsed = JavaSyntaxParser().parse(extracted.text) {
                return (extracted.url, extracted.text, parsed, nil)
            }
            return await decompiledSourceFile(stub)
        case .jar(let jar):
            if let extracted = JavaAttachedSources.extract(
                jdkHome: nil, module: nil, binaryJar: jar, topLevel: top, cacheRoot: cacheRoot
            ), let parsed = JavaSyntaxParser().parse(extracted.text) {
                return (extracted.url, extracted.text, parsed, nil)
            }
            return await decompiledSourceFile(stub)
        }
    }

    /// Falls back to decompiling `stub` itself with Sunflower — not the top-level type, since
    /// Sunflower prints a nested class as its own compilation unit. Gated by `decompile`, which
    /// Umbra wires to the one-time user agreement; a hover-triggered resolve never gets here with
    /// permission to ask, so it silently returns nil instead of decompiling.
    func decompiledSourceFile(
        _ stub: JavaClassStub
    ) async -> (url: URL?, text: String, tree: JavaSyntaxTree, relaxedSimpleName: String?)? {
        guard await decompile.allow(),
              let result = JavaClassDecompiler.decompile(stub: stub, jdkHome: jdkHome, cacheRoot: cacheRoot),
              let parsed = JavaSyntaxParser().parse(result.text) else {
            return nil
        }
        // Sunflower's own file for a nested type declares it as `Outer.Inner`; the locator needs
        // a single identifier to match against.
        let relaxedSimpleName = stub.outerQualifiedName != nil ? stub.simpleName : nil
        return (result.url, result.text, parsed, relaxedSimpleName)
    }

    func topLevel(_ stub: JavaClassStub) async -> JavaClassStub {
        var current = stub
        var seen = Set<String>()
        while seen.insert(current.qualifiedName).inserted,
              let outer = current.outerQualifiedName,
              let parent = await index.classStub(qualifiedName: outer) {
            current = parent
        }
        return current
    }

    func load(_ url: URL) async -> String? {
        if JavaNavigationText.sameFile(url, fileURL) { return source }
        if let openBuffer, let text = await openBuffer(url) { return text }
        if let provider = JavaMemberLookup.sourceTextProvider, let text = await provider(url) { return text }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// - Parameter fileContext: the file to resolve simple names against; this session's own by default.
    func resolveType(components: [String], in fileContext: JavaResolutionContext? = nil) async -> JavaTypeRef? {
        let context = fileContext ?? self.context
        guard let head = components.first else { return nil }
        let full = components.joined(separator: ".")
        if await index.classStub(qualifiedName: full) != nil {
            return .classType(qualifiedName: full, arguments: [], outer: nil)
        }
        let resolvedHead = await JavaTypeResolver.resolve(
            .unresolved(simpleName: head, arguments: []), context: context, index: index
        )
        if components.count == 1 { return resolvedHead }
        guard case .classType(var current, _, _) = resolvedHead else { return nil }
        for component in components.dropFirst() {
            let candidate = "\(current).\(component)"
            if await index.classStub(qualifiedName: candidate) != nil {
                current = candidate
                continue
            }
            if let stub = await index.classStub(qualifiedName: current),
               let inner = stub.innerTypeNames.first(where: { $0 == candidate || $0.hasSuffix(".\(component)") }) {
                current = inner
                continue
            }
            return nil
        }
        return .classType(qualifiedName: current, arguments: [], outer: nil)
    }

    func dotOffset(before node: SyntaxNode) -> Int? {
        let bytes = Array(source.utf8)
        var index = node.startByte - 1
        while index >= 0 {
            let byte = bytes[index]
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                index -= 1
                continue
            }
            return byte == UInt8(ascii: ".") ? index : nil
        }
        return nil
    }

    func hit(text: String, url: URL?, byteRange: Range<Int>, displayName: String) -> JavaDefinitionHit {
        JavaDefinitionHit(
            url: url,
            range: JavaNavigationText.textRange(for: byteRange, in: text),
            displayName: displayName
        )
    }

    func dedupe(_ hits: [JavaDefinitionHit]) -> [JavaDefinitionHit] {
        var seen = Set<String>()
        return hits.filter { hit in
            let key = "\(hit.url?.standardizedFileURL.path ?? "")#\(hit.range.start.utf16Offset)-\(hit.range.end.utf16Offset)"
            return seen.insert(key).inserted
        }
    }

    static func methodTypeParameters(in tree: JavaSyntaxTree, atByteOffset byteOffset: Int) -> Set<String> {
        var names = Set<String>()
        var current: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        while let node = current {
            if node.type == "method_declaration" || node.type == "constructor_declaration",
               let parameters = node.child(byFieldName: "type_parameters") {
                for parameter in parameters.namedChildren(ofType: "type_parameter") {
                    if let name = parameter.child(byFieldName: "name") ?? parameter.namedChild(at: 0) {
                        names.insert(name.text)
                    }
                }
            }
            current = node.parent
        }
        return names
    }
}
