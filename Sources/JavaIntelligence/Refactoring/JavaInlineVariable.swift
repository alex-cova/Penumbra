import EditorIntelligence
import Foundation

enum JavaInlineVariable {
    static func isAvailable(
        source: String, context: RefactoringContext, url: URL, index: JavaIndex
    ) async -> Bool {
        guard context.selection.additionalRanges.isEmpty else { return false }
        guard let target = await resolveTarget(source: source, context: context, url: url, index: index) else { return false }
        return analyze(target: target, source: source, url: url).blockingError == nil
    }

    static func plan(
        source: String, context: RefactoringContext, url: URL, index: JavaIndex
    ) async -> WorkspaceEditPlan {
        let title = "Inline Variable"
        if !context.selection.additionalRanges.isEmpty {
            return WorkspaceEditPlan(blockingError: "Inline Variable works with a single caret or selection.", title: title)
        }
        guard let target = await resolveTarget(source: source, context: context, url: url, index: index) else {
            return WorkspaceEditPlan(blockingError: "Place the caret on a local variable to inline.", title: title)
        }
        let analysis = analyze(target: target, source: source, url: url)
        if let blocking = analysis.blockingError {
            return WorkspaceEditPlan(blockingError: blocking, title: title)
        }
        guard let info = analysis.info else {
            return WorkspaceEditPlan(blockingError: "Could not inline this variable.", title: title)
        }

        let replacement = parenthesizedIfNeeded(info.initializerText)
        var entries: [WorkspaceEditPlanEntry] = []
        for usage in info.usages where usage.kind != .declaration {
            entries.append(JavaRefactoringText.planEntry(
                url: url, byteRange: usage.byteRange, oldText: info.name, newText: replacement,
                source: source, description: "Replace reference"
            ))
        }
        entries.append(JavaRefactoringText.planEntry(
            url: url, byteRange: info.declarationRemovalRange,
            oldText: info.declarationRemovalText, newText: "",
            source: source, description: "Remove declaration"
        ))
        return WorkspaceEditPlan(entries: entries, title: title)
    }

    // MARK: - Analysis

    private struct Target {
        let tree: JavaSyntaxTree
        let localID: JavaSymbolID
        let name: String
    }

    private struct VariableInfo {
        let name: String
        let initializerText: String
        let usages: [JavaUsage]
        let declarationRemovalRange: Range<Int>
        let declarationRemovalText: String
    }

    private struct Analysis {
        var info: VariableInfo?
        var blockingError: String?
    }

    private static func resolveTarget(
        source: String, context: RefactoringContext, url: URL, index: JavaIndex
    ) async -> Target? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        if let selectionRange = JavaRefactoringText.selectionByteRange(in: source, selection: context.selection),
           !selectionRange.isEmpty,
           let declarator = localDeclarator(in: tree, covering: selectionRange) {
            guard let nameNode = declarator.child(byFieldName: "name") else { return nil }
            let id: JavaSymbolID = .local(file: url.standardizedFileURL, declarationRange: nameNode.byteRange)
            return Target(tree: tree, localID: id, name: nameNode.text)
        }
        guard let offset = JavaRefactoringText.caretUTF16Offset(in: context.cursor, source: source),
              let token = JavaRefactoringText.identifierToken(atUTF16Offset: offset, in: source) else { return nil }
        let environment = JavaReferenceEnvironment(index: index, cacheRoot: url.deletingLastPathComponent())
        guard let id = await JavaSymbolIdentity.symbolID(
            at: offset, in: source, url: url, environment: environment
        ), case .local = id else { return nil }
        return Target(tree: tree, localID: id, name: token.0.text)
    }

    private static func analyze(target: Target, source: String, url: URL) -> Analysis {
        guard case .local(let file, let declarationRange) = target.localID,
              JavaNavigationText.sameFile(file, url) else {
            return Analysis(blockingError: "Only locals in this file can be inlined.")
        }
        guard let declarator = localDeclarator(forDeclaration: declarationRange, in: target.tree) else {
            return Analysis(blockingError: "Only local variables can be inlined.")
        }
        guard declarator.parent?.type == "local_variable_declaration" else {
            return Analysis(blockingError: "Parameters and other bindings cannot be inlined.")
        }
        let declaration = declarator.parent!
        if declaration.namedChildren(ofType: "variable_declarator").count > 1 {
            return Analysis(blockingError: "Inline one variable at a time when several are declared together.")
        }
        guard let initializer = declarator.child(byFieldName: "value") else {
            return Analysis(blockingError: "The variable has no initializer to inline.")
        }
        let usages = JavaLocalUsages.usages(of: target.localID, in: source)
        if usages.contains(where: { $0.kind == .write }) {
            return Analysis(blockingError: "The variable is assigned after it is declared.")
        }
        guard let removal = declarationRemoval(for: declaration, in: source) else {
            return Analysis(blockingError: "Could not remove the declaration.")
        }
        return Analysis(info: VariableInfo(
            name: target.name,
            initializerText: initializer.text,
            usages: usages,
            declarationRemovalRange: removal.range,
            declarationRemovalText: removal.text
        ))
    }

    private static func localDeclarator(in tree: JavaSyntaxTree, covering range: Range<Int>) -> SyntaxNode? {
        let node = tree.node(inByteRange: range)
        var current: SyntaxNode? = node
        while let next = current {
            if next.type == "variable_declarator" { return next }
            if next.type == "local_variable_declaration" {
                return next.namedChildren(ofType: "variable_declarator").first
            }
            current = next.parent
        }
        return nil
    }

    private static func localDeclarator(forDeclaration range: Range<Int>, in tree: JavaSyntaxTree) -> SyntaxNode? {
        let node = tree.node(atByteOffset: range.lowerBound)
        var current: SyntaxNode? = node
        while let next = current {
            if next.type == "variable_declarator",
               next.child(byFieldName: "name")?.byteRange == range {
                return next
            }
            current = next.parent
        }
        return nil
    }

    private static func declarationRemoval(for declaration: SyntaxNode, in source: String) -> (range: Range<Int>, text: String)? {
        let bytes = Array(source.utf8)
        var start = declaration.startByte
        var end = declaration.endByte
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

    private static func parenthesizedIfNeeded(_ expression: String) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("(") || !trimmed.hasSuffix(")") else { return trimmed }
        if trimmed.contains(where: { "+-*/%&|^?:<>".contains($0) }) {
            return "(\(trimmed))"
        }
        return trimmed
    }
}

private extension UInt8 {
    var asciiLineBreak: Bool { self == 10 || self == 13 }
}
