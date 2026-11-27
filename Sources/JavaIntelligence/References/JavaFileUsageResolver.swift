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
        return await usages(of: [target], source: source, url: url, environment: environment)[target] ?? []
    }

    /// Resolves a batch of non-local targets against one file snapshot.
    static func usages(
        of targets: [JavaSymbolID], source: String, url: URL, environment: JavaReferenceEnvironment
    ) async -> [JavaSymbolID: [JavaUsage]] {
        let targets = targets.filter { !$0.simpleName.isEmpty && source.contains($0.simpleName) }
        guard !targets.isEmpty, !Task.isCancelled, let tree = JavaSyntaxParser().parse(source) else { return [:] }

        let file = JavaSourceStubBuilder.build(tree: tree, url: url)
        let locator = JavaUsageLocator(url: url, text: source)
        let gate = JavaDecompileGate(policy: .denied)
        let names = Set(targets.map(\.simpleName))
        let includesConstructors = targets.contains { target in
            if case .constructor = target { return true }
            return false
        }
        let nodes = candidateNodes(named: names, includesConstructors: includesConstructors, in: tree)
        // F-08: one scope for the whole file. The scope depends only on `url`, so installing
        // it per candidate node was pure overhead; each node still gets its own session because
        // the resolution context (enclosing types, type parameters) is offset-specific.
        return await environment.withScope(for: url) {
            var result: [JavaSymbolID: [JavaUsage]] = [:]
            for target in targets {
                let name = target.simpleName
                var found: [Range<Int>: JavaUsage] = [:]
                var candidates = nodes.byName[name] ?? []
                if case .constructor = target { candidates.append(contentsOf: nodes.constructorKeywords) }
                for node in candidates {
                    if Task.isCancelled { return result }
                    let session = JavaNavigationSession(
                        source: source, fileURL: url, tree: tree, byteOffset: node.startByte, fileStubs: file,
                        index: environment.index, jdkHome: environment.jdkHome, cacheRoot: environment.cacheRoot,
                        openBuffer: environment.openBuffer, decompile: gate
                    )
                    if let usage = await resolve(node, target: target, session: session, locator: locator),
                       found[usage.byteRange] == nil { found[usage.byteRange] = usage }
                }
                result[target] = found.values.sorted { $0.byteRange.lowerBound < $1.byteRange.lowerBound }
            }
            return result
        }
    }

    // MARK: - Per identifier

    private static func resolve(
        _ node: SyntaxNode, target: JavaSymbolID, session: JavaNavigationSession, locator: JavaUsageLocator
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
            session.tree.visibleLocals(atByteOffset: reference.startByte),
            context: session.context, index: session.index
        )
        guard let typed = await JavaExpressionTyper.typed(receiverNode, locals: locals, context: session.context, index: session.index),
              typed.packageName == nil else { return nil }
        let qualifier: JavaMemberQualifier = receiverNode.type == "super" ? .viaSuper : .expression
        let methods = await session.allMethods(named: node.text, on: typed.type, mode: .instance, qualifier: qualifier)
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
    private static func candidateNodes(
        named names: Set<String>, includesConstructors: Bool, in tree: JavaSyntaxTree
    ) -> (byName: [String: [SyntaxNode]], constructorKeywords: [SyntaxNode]) {
        var byName: [String: [SyntaxNode]] = [:]
        var constructorKeywords: [SyntaxNode] = []
        var stack = [tree.rootNode]
        while !Task.isCancelled, let node = stack.popLast() {
            if node.type == "package_declaration" { continue }
            switch node.type {
            case "identifier", "type_identifier":
                let name = node.text
                if names.contains(name) { byName[name, default: []].append(node) }
            case "explicit_constructor_invocation":
                if includesConstructors, let keyword = node.children.first, keyword.type == "this" || keyword.type == "super" {
                    constructorKeywords.append(keyword)
                }
                stack.append(contentsOf: node.children)
            default:
                stack.append(contentsOf: node.children)
            }
        }
        return (byName, constructorKeywords)
    }
}
