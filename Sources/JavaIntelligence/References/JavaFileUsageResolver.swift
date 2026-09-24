import Foundation

/// Finds the usages of one symbol inside one file: parse once, then for every identifier spelled
/// like the target, classify it, resolve it and compare identities.
public enum JavaFileUsageResolver {
    /// Every declaration and use of `target` in `source` (the text of `url`).
    ///
    /// - A type target also reports the names of its own constructors as `.declaration`.
    /// - A call whose overload cannot be pinned reports each tied candidate as `.ambiguous`, and a
    ///   qualified access whose receiver cannot be typed is reported `.ambiguous` when its name
    ///   matches.
    public static func usages(
        of target: JavaSymbolID, source: String, url: URL, environment: JavaReferenceEnvironment
    ) async -> [JavaUsage] {
        if case .local(let file, let range) = target {
            guard JavaNavigationText.sameFile(file, url), let tree = JavaSyntaxParser().parse(source) else { return [] }
            return JavaLocalUsages.usages(ofDeclaration: range, file: url, source: source, tree: tree)
        }
        let name = target.simpleName
        guard !name.isEmpty, source.contains(name), let tree = JavaSyntaxParser().parse(source) else { return [] }

        let file = JavaSourceStubBuilder.build(tree: tree, url: url)
        let locator = JavaUsageLocator(url: url, text: source)
        let gate = JavaDecompileGate(policy: .denied)
        var found: [Range<Int>: JavaUsage] = [:]

        for node in candidateNodes(named: name, target: target, in: tree) {
            if Task.isCancelled { break }
            let session = JavaNavigationSession(
                source: source, fileURL: url, tree: tree, byteOffset: node.startByte, fileStubs: file,
                index: environment.index, jdkHome: environment.jdkHome, cacheRoot: environment.cacheRoot,
                openBuffer: environment.openBuffer, decompile: gate
            )
            let usage = await environment.withScope(for: url) {
                await resolve(node, target: target, name: name, session: session, locator: locator)
            }
            if let usage, found[usage.byteRange] == nil { found[usage.byteRange] = usage }
        }
        return found.values.sorted { $0.byteRange.lowerBound < $1.byteRange.lowerBound }
    }

    // MARK: - Per identifier

    private static func resolve(
        _ node: SyntaxNode, target: JavaSymbolID, name: String, session: JavaNavigationSession, locator: JavaUsageLocator
    ) async -> JavaUsage? {
        // `Foo::bar`: the name after `::` is not something the classifier understands.
        if node.type == "identifier", let parent = node.parent, parent.type == "method_reference",
           parent.namedChildren.last?.byteRange == node.byteRange, parent.namedChildCount > 1 {
            guard case .method = target else { return nil }
            return await methodReferenceUsage(node, reference: parent, target: target, session: session, locator: locator)
        }
        guard let reference = JavaReferenceClassifier.classify(token: node) else { return nil }
        let resolved = await session.resolveReference(token: node, reference: reference)
        if let match = resolved.ids.first(where: { $0.id == target }) {
            return locator.usage(byteRange: node.byteRange, kind: match.kind, confidence: match.confidence)
        }
        if case .declaration = reference, case .type(let qualifiedName) = target,
           let parent = node.parent, parent.type == "constructor_declaration" || parent.type == "compact_constructor_declaration",
           session.context.enclosingTypeQualifiedNames.first == qualifiedName {
            return locator.usage(byteRange: node.byteRange, kind: .declaration, confidence: .exact)
        }
        if resolved.receiverUnknown {
            switch target {
            case .method:
                if case .methodCall = reference {
                    return locator.usage(byteRange: node.byteRange, kind: .call, confidence: .ambiguous)
                }
            case .field:
                if case .fieldAccess = reference {
                    return locator.usage(byteRange: node.byteRange, kind: .read, confidence: .ambiguous)
                }
            default:
                break
            }
        }
        return nil
    }

    private static func methodReferenceUsage(
        _ node: SyntaxNode, reference: SyntaxNode, target: JavaSymbolID, session: JavaNavigationSession, locator: JavaUsageLocator
    ) async -> JavaUsage? {
        guard let receiverNode = reference.namedChild(at: 0), receiverNode.byteRange != node.byteRange else { return nil }
        let locals = await JavaExpressionTyper.resolvingVarLocals(
            JavaLocalScope.locals(in: session.tree, atByteOffset: reference.startByte),
            context: session.context, index: session.index
        )
        guard let typed = await JavaExpressionTyper.typed(receiverNode, locals: locals, context: session.context, index: session.index),
              typed.packageName == nil else { return nil }
        let methods = await session.allMethods(named: node.text, on: typed.type, mode: .instance)
        var ids: [JavaSymbolID] = []
        for method in methods {
            let id = session.methodID(await session.declaredMethod(method), declaringClass: method.declaringClass)
            if !ids.contains(id) { ids.append(id) }
        }
        guard ids.contains(target) else { return nil }
        return locator.usage(byteRange: node.byteRange, kind: .methodReference, confidence: ids.count > 1 ? .ambiguous : .exact)
    }

    // MARK: - Candidates

    /// Identifier nodes spelled `name` (plus `this`/`super` keywords when a constructor is the
    /// target), skipping package declarations.
    private static func candidateNodes(named name: String, target: JavaSymbolID, in tree: JavaSyntaxTree) -> [SyntaxNode] {
        var isConstructor = false
        if case .constructor = target { isConstructor = true }
        var result: [SyntaxNode] = []
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "package_declaration" { continue }
            switch node.type {
            case "identifier", "type_identifier":
                if node.text == name { result.append(node) }
            case "explicit_constructor_invocation":
                if isConstructor, let keyword = node.children.first, keyword.type == "this" || keyword.type == "super" {
                    result.append(keyword)
                }
                stack.append(contentsOf: node.children)
            default:
                stack.append(contentsOf: node.children)
            }
        }
        return result.sorted { $0.startByte < $1.startByte }
    }
}
