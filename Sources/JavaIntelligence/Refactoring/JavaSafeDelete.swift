import EditorIntelligence
import Foundation

/// Deletes a class, method, or field when it has no usages outside its declaration.
enum JavaSafeDelete {
    static let title = "Safe Delete"

    // MARK: - Availability

    static func isAvailable(
        source: String, caretOffset: Int, url: URL, environment: JavaReferenceEnvironment, index: JavaIndex
    ) async -> Bool {
        await resolveDeletable(
            source: source, caretOffset: caretOffset, url: url, environment: environment, index: index
        ) != nil
    }

    // MARK: - Plan

    static func plan(
        source: String, caretOffset: Int, url: URL,
        index: JavaIndex, candidates: any JavaUsageCandidateSource, roots: [URL],
        environment: JavaReferenceEnvironment, isReadOnly: @Sendable (URL) -> Bool
    ) async -> WorkspaceEditPlan {
        guard let target = await resolveDeletable(
            source: source, caretOffset: caretOffset, url: url, environment: environment, index: index
        ) else {
            return blocked("Place the caret on a class, method, or field to delete.")
        }

        if isReadOnly(target.declaringURL) {
            return blocked("\(target.displayName) is declared in generated code and cannot be deleted.")
        }

        let usages = await collectUsages(
            target: target, documentURL: url, candidates: candidates, roots: roots, environment: environment
        )
        let external = usages.filter { $0.kind != .declaration }
        if !external.isEmpty {
            let files = Set(external.map { $0.url.lastPathComponent }).sorted().joined(separator: ", ")
            return blocked("\(external.count) usage\(external.count == 1 ? "" : "s") in \(files) block safe delete.")
        }

        var plan = WorkspaceEditPlan(title: title)
        switch target.kind {
        case .topLevelType:
            plan.fileDeletions = [target.declaringURL]
            plan.entries = []
        case .member:
            guard let text = await readText(of: target.declaringURL, environment: environment) else {
                return blocked("Could not read \(target.declaringURL.lastPathComponent).")
            }
            guard let deletion = memberDeletionEntry(
                source: text, url: target.declaringURL, caretOffset: caretOffset, symbolID: target.symbolID
            ) else {
                return blocked("Could not locate the declaration to delete.")
            }
            plan.entries = [deletion]
        }
        return plan
    }

    // MARK: - Target resolution

    private enum TargetKind {
        case topLevelType
        case member
    }

    private struct DeletableTarget {
        let kind: TargetKind
        let symbolID: JavaSymbolID
        let declaringURL: URL
        let displayName: String
    }

    private static func resolveDeletable(
        source: String, caretOffset: Int, url: URL, environment: JavaReferenceEnvironment, index: JavaIndex
    ) async -> DeletableTarget? {
        guard var id = await JavaSymbolIdentity.symbolID(
            at: caretOffset, in: source, url: url, environment: environment
        ) else { return nil }
        guard let tokenRange = identifierRange(at: caretOffset, in: source) else { return nil }
        let name = JavaRenameProvider.text(of: tokenRange, in: source)

        switch id {
        case .constructor(let declaringClass, _):
            id = .type(qualifiedName: declaringClass)
            guard name == String(declaringClass.split(separator: ".").last ?? "") else { return nil }
            guard let stub = await index.classStub(qualifiedName: declaringClass) else { return nil }
            guard case .source(let file, _) = stub.origin else { return nil }
            let kind: TargetKind = stub.outerQualifiedName == nil ? .topLevelType : .member
            return DeletableTarget(
                kind: kind, symbolID: .type(qualifiedName: declaringClass),
                declaringURL: file.standardizedFileURL, displayName: stub.simpleName
            )
        case .type(let qualifiedName):
            guard name == String(qualifiedName.split(separator: ".").last ?? "") else { return nil }
            guard let stub = await index.classStub(qualifiedName: qualifiedName) else { return nil }
            guard case .source(let file, _) = stub.origin else { return nil }
            let kind: TargetKind = stub.outerQualifiedName == nil ? .topLevelType : .member
            return DeletableTarget(
                kind: kind, symbolID: .type(qualifiedName: qualifiedName),
                declaringURL: file.standardizedFileURL, displayName: stub.simpleName
            )
        case .method(let declaringClass, let methodName, _):
            guard id.simpleName == name else { return nil }
            guard let stub = await index.classStub(qualifiedName: declaringClass),
                  case .source(let file, _) = stub.origin else { return nil }
            return DeletableTarget(
                kind: .member, symbolID: id, declaringURL: file.standardizedFileURL, displayName: methodName
            )
        case .field(let declaringClass, let fieldName):
            guard id.simpleName == name else { return nil }
            guard let stub = await index.classStub(qualifiedName: declaringClass),
                  case .source(let file, _) = stub.origin else { return nil }
            return DeletableTarget(
                kind: .member, symbolID: id, declaringURL: file.standardizedFileURL, displayName: fieldName
            )
        default:
            return nil
        }
    }

    // MARK: - Usages

    private static func collectUsages(
        target: DeletableTarget, documentURL: URL,
        candidates: any JavaUsageCandidateSource, roots: [URL], environment: JavaReferenceEnvironment
    ) async -> [JavaUsage] {
        let searchRoots = roots.isEmpty ? [target.declaringURL.deletingLastPathComponent()] : roots
        if case .local = target.symbolID {
            return []
        }
        var targets = [target.symbolID]
        if case .method = target.symbolID {
            targets = await JavaMethodFamily.symbolIDs(of: target.symbolID, index: environment.index)
        }
        var seen = Set<String>()
        var all: [JavaUsage] = []
        for symbol in targets {
            let found = await JavaUsageSearch.collect(
                symbol, candidates: candidates, roots: searchRoots, environment: environment, includeDeclarations: true
            )
            for usage in found where seen.insert("\(usage.url.path):\(usage.byteRange.lowerBound)").inserted {
                all.append(usage)
            }
        }
        if let text = await readText(of: target.declaringURL, environment: environment) {
            let local = await JavaFileUsageResolver.usages(
                of: target.symbolID, source: text, url: target.declaringURL, environment: environment
            )
            for usage in local where seen.insert("\(usage.url.path):\(usage.byteRange.lowerBound)").inserted {
                all.append(usage)
            }
        }
        if target.declaringURL.standardizedFileURL != documentURL.standardizedFileURL,
           let text = await readText(of: documentURL, environment: environment) {
            let local = await JavaFileUsageResolver.usages(
                of: target.symbolID, source: text, url: documentURL, environment: environment
            )
            for usage in local where seen.insert("\(usage.url.path):\(usage.byteRange.lowerBound)").inserted {
                all.append(usage)
            }
        }
        return all
    }

    // MARK: - Member deletion

    private static func memberDeletionEntry(
        source: String, url: URL, caretOffset: Int, symbolID: JavaSymbolID
    ) -> WorkspaceEditPlanEntry? {
        guard let tree = JavaSyntaxParser().parse(source),
              let node = declarationNode(at: caretOffset, symbolID: symbolID, in: source, tree: tree) else {
            return nil
        }
        var range = node.byteRange
        let bytes = Array(source.utf8)
        while range.upperBound < bytes.count, bytes[range.upperBound].asciiWhitespace { range = range.lowerBound..<(range.upperBound + 1) }
        while range.upperBound < bytes.count, bytes[range.upperBound] == 10 || bytes[range.upperBound] == 13 {
            range = range.lowerBound..<(range.upperBound + 1)
        }
        let oldText = String(decoding: bytes[range], as: UTF8.self)
        return JavaRefactoringText.planEntry(
            url: url, byteRange: range, oldText: oldText, newText: "",
            source: source, description: "Delete declaration"
        )
    }

    private static func declarationNode(
        at caretOffset: Int, symbolID: JavaSymbolID, in source: String, tree: JavaSyntaxTree
    ) -> SyntaxNode? {
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: caretOffset, in: source)
        var node = tree.node(atByteOffset: byteOffset)
        let allowed: Set<String> = [
            "method_declaration", "constructor_declaration", "field_declaration",
            "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration"
        ]
        while true {
            if allowed.contains(node.type) {
                if matchesDeclaration(node, symbolID: symbolID, in: source) { return node }
            }
            guard let parent = node.parent else { break }
            node = parent
        }
        return nil
    }

    private static func matchesDeclaration(_ node: SyntaxNode, symbolID: JavaSymbolID, in source: String) -> Bool {
        let nameNode = node.child(byFieldName: "name")
        let text = nameNode.map { String(decoding: Array(source.utf8)[$0.byteRange], as: UTF8.self) } ?? ""
        switch symbolID {
        case .type(let qualified):
            return text == String(qualified.split(separator: ".").last ?? "")
        case .method(_, let name, _):
            return text == name
        case .field(_, let name):
            return text == name
        default:
            return false
        }
    }

    // MARK: - Helpers

    private static func identifierRange(at offset: Int, in source: String) -> Range<Int>? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: offset, in: source)
        func isName(_ node: SyntaxNode) -> Bool { node.type == "identifier" || node.type == "type_identifier" }
        let leaf = tree.node(atByteOffset: byteOffset)
        if leaf.byteRange.contains(byteOffset), isName(leaf) { return leaf.byteRange }
        let before = tree.node(atByteOffset: max(0, byteOffset - 1))
        guard isName(before), before.byteRange.upperBound == byteOffset else { return nil }
        return before.byteRange
    }

    private static func readText(of file: URL, environment: JavaReferenceEnvironment) async -> String? {
        if let reader = environment.openBuffer, let text = await reader(file) { return text }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    private static func blocked(_ message: String) -> WorkspaceEditPlan {
        WorkspaceEditPlan(blockingError: message, title: title)
    }
}

private extension UInt8 {
    var asciiWhitespace: Bool { self == 32 || self == 9 || self == 10 || self == 13 }
}
