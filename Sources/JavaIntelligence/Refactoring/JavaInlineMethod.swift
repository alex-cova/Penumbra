import EditorIntelligence
import Foundation

enum JavaInlineMethod {
    static func isAvailable(
        source: String, context: RefactoringContext, url: URL, index: JavaIndex, cacheRoot: URL
    ) async -> Bool {
        guard context.selection.additionalRanges.isEmpty else { return false }
        guard let target = await resolveTarget(
            source: source, context: context, url: url, index: index, cacheRoot: cacheRoot
        ) else { return false }
        return await analyze(target: target, source: source, url: url, index: index, cacheRoot: cacheRoot).blockingError == nil
    }

    static func plan(
        source: String, context: RefactoringContext, url: URL, index: JavaIndex, cacheRoot: URL
    ) async -> WorkspaceEditPlan {
        let title = "Inline Method"
        if !context.selection.additionalRanges.isEmpty {
            return WorkspaceEditPlan(blockingError: "Inline Method works with a single caret or selection.", title: title)
        }
        guard let target = await resolveTarget(
            source: source, context: context, url: url, index: index, cacheRoot: cacheRoot
        ) else {
            return WorkspaceEditPlan(blockingError: "Place the caret on a private method or one of its calls.", title: title)
        }
        let analysis = await analyze(target: target, source: source, url: url, index: index, cacheRoot: cacheRoot)
        if let blocking = analysis.blockingError {
            return WorkspaceEditPlan(blockingError: blocking, title: title)
        }
        guard let info = analysis.info else {
            return WorkspaceEditPlan(blockingError: "Could not inline this method.", title: title)
        }

        var entries: [WorkspaceEditPlanEntry] = []
        for replacement in info.callReplacements {
            entries.append(JavaRefactoringText.planEntry(
                url: url, byteRange: replacement.range, oldText: replacement.oldText, newText: replacement.newText,
                source: source, description: "Inline call"
            ))
        }
        entries.append(JavaRefactoringText.planEntry(
            url: url, byteRange: info.methodRemovalRange, oldText: info.methodRemovalText, newText: "",
            source: source, description: "Remove method"
        ))
        return WorkspaceEditPlan(entries: entries, title: title)
    }

    // MARK: - Analysis

    private struct Target {
        let tree: JavaSyntaxTree
        let methodID: JavaSymbolID
        let methodNode: SyntaxNode
    }

    private struct CallReplacement {
        let range: Range<Int>
        let oldText: String
        let newText: String
    }

    private struct MethodInfo {
        let callReplacements: [CallReplacement]
        let methodRemovalRange: Range<Int>
        let methodRemovalText: String
    }

    private struct Analysis {
        var info: MethodInfo?
        var blockingError: String?
    }

    private static func resolveTarget(
        source: String, context: RefactoringContext, url: URL, index: JavaIndex, cacheRoot: URL
    ) async -> Target? {
        guard let tree = JavaSyntaxParser().parse(source),
              let offset = JavaRefactoringText.caretUTF16Offset(in: context.cursor, source: source) else { return nil }
        let environment = JavaReferenceEnvironment(index: index, cacheRoot: cacheRoot)
        guard let id = await JavaSymbolIdentity.symbolID(
            at: offset, in: source, url: url, environment: environment
        ), case .method = id else { return nil }
        guard let methodNode = methodDeclaration(for: id, in: tree) else { return nil }
        guard let typeDecl = JavaExtractExpression.enclosingTypeDeclaration(for: methodNode),
              let enclosingType = enclosingTypeName(typeDecl: typeDecl, tree: tree, url: url) else { return nil }
        guard case .method(let declaringClass, _, _) = id, declaringClass == enclosingType else { return nil }
        return Target(tree: tree, methodID: id, methodNode: methodNode)
    }

    private static func analyze(
        target: Target, source: String, url: URL, index: JavaIndex, cacheRoot: URL
    ) async -> Analysis {
        guard case .method(_, let name, _) = target.methodID else {
            return Analysis(blockingError: "Only methods can be inlined.")
        }
        guard isPrivateMethod(target.methodNode) else {
            return Analysis(blockingError: "Only private methods can be inlined.")
        }
        guard let body = target.methodNode.child(byFieldName: "body") else {
            return Analysis(blockingError: "The method has no body.")
        }
        if containsRecursiveCall(to: name, in: body) {
            return Analysis(blockingError: "Recursive methods cannot be inlined.")
        }
        let returnStatements = returnStatements(in: body)
        if returnStatements.count > 1 {
            return Analysis(blockingError: "Methods with multiple return statements cannot be inlined yet.")
        }

        let environment = JavaReferenceEnvironment(index: index, cacheRoot: cacheRoot)
        let usages = await JavaFileUsageResolver.usages(
            of: target.methodID, source: source, url: url, environment: environment
        )
        let calls = usages.filter { $0.kind == .call && JavaNavigationText.sameFile($0.url, url) }
        if calls.isEmpty {
            return Analysis(blockingError: "There are no calls to inline.")
        }
        if calls.contains(where: { $0.confidence == .ambiguous }) {
            return Analysis(blockingError: "Some calls could not be tied to this overload.")
        }

        let parameters = formalParameters(in: target.methodNode)
        var replacements: [CallReplacement] = []
        for call in calls {
            guard let invocation = methodInvocation(at: call.byteRange.lowerBound, in: target.tree) else { continue }
            guard let replacement = inlineCall(
                invocation, parameters: parameters, body: body, returnStatements: returnStatements,
                tree: target.tree, source: source, url: url
            ) else {
                return Analysis(blockingError: "Could not inline a call site.")
            }
            replacements.append(replacement)
        }
        guard let removal = memberRemoval(for: target.methodNode, in: source) else {
            return Analysis(blockingError: "Could not remove the method.")
        }
        return Analysis(info: MethodInfo(
            callReplacements: replacements.sorted { $0.range.lowerBound > $1.range.lowerBound },
            methodRemovalRange: removal.range,
            methodRemovalText: removal.text
        ))
    }

    // MARK: - Inlining

    private static func inlineCall(
        _ invocation: SyntaxNode,
        parameters: [(name: String, declarationRange: Range<Int>)],
        body: SyntaxNode,
        returnStatements: [SyntaxNode],
        tree: JavaSyntaxTree,
        source: String,
        url: URL
    ) -> CallReplacement? {
        guard let arguments = invocation.child(byFieldName: "arguments")?.namedChildren else { return nil }
        guard arguments.count == parameters.count else { return nil }

        if let returnStatement = returnStatements.first,
           let value = returnStatement.child(byFieldName: "value") ?? returnStatement.namedChild(at: 0) {
            let substituted = substituteParameters(
                in: value.byteRange, parameters: parameters, arguments: arguments, source: source, url: url, body: body
            )
            let replacementText = replacementForCall(
                invocation, expression: parenthesizedIfNeeded(substituted), tree: tree
            )
            return CallReplacement(
                range: replacementText.range, oldText: replacementText.oldText, newText: replacementText.newText
            )
        }

        let statements = bodyStatements(in: body)
        let callIndent = leadingIndent(for: invocation, in: source)
        let inlined = statements.map { statement in
            let text = substituteParameters(
                in: statement.byteRange, parameters: parameters, arguments: arguments, source: source, url: url, body: body
            )
            return JavaExtractExpression.reindentedBody(
                text.hasSuffix("\n") ? text : text + "\n", bodyIndent: callIndent
            )
        }.joined()
        let replacementText = replacementForCall(invocation, expression: inlined, tree: tree)
        return CallReplacement(
            range: replacementText.range, oldText: replacementText.oldText, newText: replacementText.newText
        )
    }

    private static func replacementForCall(
        _ invocation: SyntaxNode, expression: String, tree: JavaSyntaxTree
    ) -> (range: Range<Int>, oldText: String, newText: String) {
        if let statement = ancestor(of: invocation, type: "expression_statement") {
            return (statement.byteRange, tree.text(in: statement.byteRange), expression.hasSuffix(";") ? expression : expression + ";")
        }
        return (invocation.byteRange, tree.text(in: invocation.byteRange), expression)
    }

    private static func substituteParameters(
        in targetRange: Range<Int>,
        parameters: [(name: String, declarationRange: Range<Int>)],
        arguments: [SyntaxNode],
        source: String,
        url: URL,
        body: SyntaxNode
    ) -> String {
        var replacements: [(Range<Int>, String)] = []
        for (parameter, argument) in zip(parameters, arguments) {
            let paramID: JavaSymbolID = .local(file: url.standardizedFileURL, declarationRange: parameter.declarationRange)
            for usage in JavaLocalUsages.usages(of: paramID, in: source) where usage.kind != .declaration {
                guard body.byteRange.contains(usage.byteRange), targetRange.contains(usage.byteRange) else { continue }
                replacements.append((usage.byteRange, parenthesizedIfNeeded(argument.text)))
            }
        }
        var localBytes = Array(String(decoding: Array(source.utf8)[targetRange], as: UTF8.self).utf8)
        let offset = targetRange.lowerBound
        for (range, replacement) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            let local = (range.lowerBound - offset)..<(range.upperBound - offset)
            localBytes.replaceSubrange(local, with: Array(replacement.utf8))
        }
        return String(decoding: localBytes, as: UTF8.self)
    }

    // MARK: - Tree helpers

    private static func methodDeclaration(for id: JavaSymbolID, in tree: JavaSyntaxTree) -> SyntaxNode? {
        guard case .method(let declaringClass, let name, let keys) = id else { return nil }
        let ranges = JavaDeclarationLocator.methodRanges(
            declaringClass: declaringClass, name: name, parameterKeys: keys, isConstructor: false, in: tree
        )
        guard ranges.count == 1, let range = ranges.first else { return nil }
        return ancestor(of: tree.node(atByteOffset: range.lowerBound), type: "method_declaration")
    }

    private static func methodInvocation(at byteOffset: Int, in tree: JavaSyntaxTree) -> SyntaxNode? {
        let token = tree.node(atByteOffset: byteOffset)
        return ancestor(of: token, type: "method_invocation")
    }

    private static func ancestor(of node: SyntaxNode, type: String) -> SyntaxNode? {
        var current = node.parent
        while let next = current {
            if next.type == type { return next }
            current = next.parent
        }
        return nil
    }

    private static func enclosingTypeName(typeDecl: SyntaxNode, tree: JavaSyntaxTree, url: URL) -> String? {
        let fileStubs = JavaSourceStubBuilder.build(tree: tree, url: url)
        let context = JavaCompletionProvider.resolutionContext(
            in: tree, fileStubs: fileStubs, atByteOffset: typeDecl.startByte
        )
        return context.enclosingTypeQualifiedNames.first
    }

    private static func isPrivateMethod(_ method: SyntaxNode) -> Bool {
        if let modifiers = method.child(byFieldName: "modifiers")
            ?? method.namedChildren.first(where: { $0.type == "modifiers" }) {
            if modifiers.text.contains("private") { return true }
            if modifiers.children.contains(where: { $0.type == "private" }) { return true }
        }
        return method.children.contains(where: { $0.type == "private" })
    }

    private static func formalParameters(in method: SyntaxNode) -> [(name: String, declarationRange: Range<Int>)] {
        guard let parameters = method.child(byFieldName: "parameters") else { return [] }
        return parameters.namedChildren.compactMap { child in
            guard child.type == "formal_parameter",
                  let nameNode = child.child(byFieldName: "name") else { return nil }
            return (nameNode.text, nameNode.byteRange)
        }
    }

    private static func bodyStatements(in body: SyntaxNode) -> [SyntaxNode] {
        body.namedChildren.filter { $0.type != "{" && $0.type != "}" }
    }

    private static func returnStatements(in body: SyntaxNode) -> [SyntaxNode] {
        var found: [SyntaxNode] = []
        collectReturnStatements(in: body, into: &found)
        return found
    }

    private static func collectReturnStatements(in node: SyntaxNode, into found: inout [SyntaxNode]) {
        if node.type == "return_statement" { found.append(node) }
        for child in node.namedChildren where child.type != "lambda_expression" {
            collectReturnStatements(in: child, into: &found)
        }
    }

    private static func containsRecursiveCall(to name: String, in body: SyntaxNode) -> Bool {
        var stack = [body]
        while let node = stack.popLast() {
            if node.type == "method_invocation",
               node.child(byFieldName: "name")?.text == name,
               node.child(byFieldName: "object") == nil {
                return true
            }
            stack.append(contentsOf: node.namedChildren)
        }
        return false
    }

    private static func memberRemoval(for method: SyntaxNode, in source: String) -> (range: Range<Int>, text: String)? {
        let bytes = Array(source.utf8)
        var start = method.startByte
        var end = method.endByte
        while end < bytes.count, bytes[end].asciiLineBreak { end += 1 }
        while start > 0, bytes[start - 1].asciiLineBreak {
            let lineStart = start
            var scan = start - 1
            while scan > 0, !bytes[scan - 1].asciiLineBreak { scan -= 1 }
            let linePrefix = String(decoding: bytes[scan..<lineStart], as: UTF8.self)
            if linePrefix.allSatisfy({ $0.isWhitespace }) {
                start = scan
            } else {
                break
            }
        }
        guard start < end else { return nil }
        return (start..<end, String(decoding: bytes[start..<end], as: UTF8.self))
    }

    private static func leadingIndent(for node: SyntaxNode, in source: String) -> String {
        JavaExtractExpression.leadingIndent(forNode: node, in: source)
    }

    private static func parenthesizedIfNeeded(_ expression: String) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("("), trimmed.hasSuffix(")"), trimmed.count > 2 { return trimmed }
        return "(\(trimmed))"
    }
}

private extension UInt8 {
    var asciiLineBreak: Bool { self == 10 || self == 13 }
}
