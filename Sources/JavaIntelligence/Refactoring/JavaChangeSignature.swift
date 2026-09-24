import EditorIntelligence
import Foundation

/// Change Method Signature: rename a method and/or add a trailing parameter (with a default at
/// call sites) or remove the last parameter. Uses the override family and project-wide usage search
/// like rename.
enum JavaChangeSignature {
    static let title = "Change Method Signature"

    struct Request: Sendable {
        let newName: String
        let addParameter: (type: String, name: String, defaultValue: String)?
        let removeLastParameter: Bool
    }

    // MARK: - Availability

    static func suggestedParameters(
        source: String, caretOffset: Int, url: URL, environment: JavaReferenceEnvironment
    ) async -> [String: String]? {
        guard let resolved = await resolveMethod(source: source, caretOffset: caretOffset, url: url, environment: environment) else {
            return nil
        }
        return [
            "newName": resolved.oldName,
            "addParameterType": "int",
            "addParameterName": "value",
            "addParameterDefault": "0",
            "removeLastParameter": ""
        ]
    }

    static func isAvailable(
        source: String, caretOffset: Int, url: URL, environment: JavaReferenceEnvironment
    ) async -> Bool {
        await resolveMethod(source: source, caretOffset: caretOffset, url: url, environment: environment) != nil
    }

    // MARK: - Plan

    static func plan(
        source: String, caretOffset: Int, url: URL, request: Request,
        index: JavaIndex, candidates: any JavaUsageCandidateSource, roots: [URL],
        environment: JavaReferenceEnvironment, isReadOnly: @Sendable (URL) -> Bool
    ) async -> WorkspaceEditPlan {
        guard let resolved = await resolveMethod(source: source, caretOffset: caretOffset, url: url, environment: environment) else {
            return blocked("Place the caret on a method declaration or call.")
        }
        if let problem = JavaRenameProvider.validate(request.newName) {
            return blocked(problem)
        }
        if request.addParameter != nil && request.removeLastParameter {
            return blocked("Add a parameter or remove the last one, not both.")
        }
        if request.newName == resolved.oldName && request.addParameter == nil && !request.removeLastParameter {
            return blocked("Change the method name, add a parameter, or remove the last parameter.")
        }

        let id = resolved.id
        guard case .method(let declaringClass, let oldName, let keys) = id else {
            return blocked("Constructors cannot be changed with this refactoring.")
        }

        let members = await JavaMethodFamily.members(of: id, index: index)
        if members.isEmpty {
            return blocked("\(oldName) could not be found in the project index.")
        }

        var declaringFiles: [URL] = []
        for member in members {
            guard case .source(let file, _)? = member.origin else {
                let message = member.declaringClass == declaringClass
                    ? "\(oldName) is declared in a library and cannot be changed."
                    : "\(oldName) overrides a library method (\(member.declaringClass)): cannot change."
                return blocked(message)
            }
            if isReadOnly(file) {
                let message = member.declaringClass == declaringClass
                    ? "\(oldName) is declared in generated code and cannot be changed."
                    : "\(oldName) overrides a method in generated code (\(member.declaringClass)): cannot change."
                return blocked(message)
            }
            declaringFiles.append(file.standardizedFileURL)
        }

        if members.contains(where: { $0.method.modifiers.contains(.varargs) }) {
            return blocked("Varargs methods are not supported yet.")
        }
        for member in members {
            if let stub = await index.classStub(qualifiedName: member.declaringClass), stub.kind == .annotationKind {
                return blocked("Annotation methods are not supported yet.")
            }
        }

        if request.removeLastParameter {
            let arity = members.map { $0.method.parameters.count }.min() ?? 0
            if arity == 0 {
                return blocked("\(oldName) has no parameters to remove.")
            }
        }

        if let add = request.addParameter {
            if let problem = JavaRefactoringText.validateIdentifier(add.name) { return blocked(problem) }
            if add.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return blocked("Enter a parameter type.")
            }
            if add.defaultValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return blocked("Enter a default value for existing call sites.")
            }
        }

        var plan = WorkspaceEditPlan(title: title)
        if request.newName != oldName {
            var conflictClasses = Set<String>()
            for member in members {
                conflictClasses.formUnion(await JavaMemberLookup.supertypeClosure(of: member.declaringClass, index: index))
                conflictClasses.insert(member.declaringClass)
            }
            for cls in conflictClasses.sorted() {
                guard let stub = await index.classStub(qualifiedName: cls) else { continue }
                if stub.methods.contains(where: { !$0.isConstructor && $0.name == request.newName && JavaTypeKeys.keys(of: $0) == keys }) {
                    plan.warnings.append("\(cls) already declares \(request.newName)(\(keys.joined(separator: ", "))).")
                    break
                }
            }
        }

        var targets = [id]
        for member in members {
            let memberID = JavaSymbolID.method(
                declaringClass: member.declaringClass, name: oldName, parameterKeys: JavaTypeKeys.keys(of: member.method)
            )
            if !targets.contains(memberID) { targets.append(memberID) }
        }

        let usages = await collectUsages(
            targets, oldName: oldName, declaringFiles: declaringFiles, documentURL: url,
            candidates: candidates, roots: roots, environment: environment
        )

        var entries: [WorkspaceEditPlanEntry] = []
        var seen = Set<String>()
        func append(_ entry: WorkspaceEditPlanEntry) {
            let key = "\(entry.url.path):\(entry.range.start.utf16Offset)"
            guard seen.insert(key).inserted else { return }
            entries.append(entry)
        }

        let rename = request.newName != oldName
        let add = request.addParameter
        let removeLast = request.removeLastParameter

        for usage in usages {
            let readOnly = isReadOnly(usage.url)
            let ambiguous = usage.confidence == .ambiguous
            guard let text = await readText(of: usage.url, environment: environment),
                  let tree = JavaSyntaxParser().parse(text) else { continue }
            let node = tree.node(atByteOffset: usage.byteRange.lowerBound)
            guard node.byteRange == usage.byteRange else { continue }

            if rename {
                append(entry(
                    url: usage.url, byteRange: usage.byteRange, oldText: oldName, newText: request.newName,
                    source: text, description: "rename", ambiguous: ambiguous, readOnly: readOnly
                ))
            }

            if usage.kind == .declaration, let method = enclosingMethodDeclaration(of: node) {
                if hasVarargs(method) { continue }
                if let parameters = method.child(byFieldName: "parameters"),
                   let newText = rebuildFormalParameters(parameters, add: add.map { ($0.type, $0.name) }, removeLast: removeLast) {
                    append(entry(
                        url: usage.url, byteRange: parameters.byteRange, oldText: parameters.text, newText: newText,
                        source: text, description: "update declaration", ambiguous: false, readOnly: readOnly
                    ))
                }
            } else if usage.kind == .call, let invocation = enclosingMethodInvocation(of: node) {
                if let arguments = invocation.child(byFieldName: "arguments"),
                   let newText = rebuildArgumentList(
                    arguments, addDefault: add?.defaultValue, removeLast: removeLast, oldArity: keys.count
                   ) {
                    append(entry(
                        url: usage.url, byteRange: arguments.byteRange, oldText: arguments.text, newText: newText,
                        source: text, description: "update call site", ambiguous: ambiguous, readOnly: readOnly
                    ))
                }
            }
        }

        if rename {
            let isStatic = members.contains { $0.method.modifiers.contains(.staticFlag) }
            if isStatic {
                for file in await staticImportFiles(
                    owners: members.map(\.declaringClass), member: oldName, declaringFiles: declaringFiles,
                    candidates: candidates, roots: roots, environment: environment
                ) {
                    guard let text = await readText(of: file, environment: environment) else { continue }
                    for owner in Set(members.map(\.declaringClass)) {
                        for usage in JavaRenameProvider.staticImportUsages(owner: owner, member: oldName, in: text, url: file) {
                            append(entry(
                                url: file, byteRange: usage.byteRange, oldText: oldName, newText: request.newName,
                                source: text, description: "update static import", ambiguous: false, readOnly: isReadOnly(file)
                            ))
                        }
                    }
                }
            }
        }

        entries.sort {
            $0.url.path != $1.url.path ? $0.url.path < $1.url.path : $0.range.start.utf16Offset < $1.range.start.utf16Offset
        }
        plan.entries = entries
        if entries.contains(where: \.isReadOnly) {
            plan.warnings.append("Some usages are in generated files and will not be changed.")
        }
        let ambiguous = entries.filter(\.isAmbiguous).count
        if ambiguous > 0 {
            plan.warnings.append(
                "\(ambiguous) call site\(ambiguous == 1 ? "" : "s") could not be resolved exactly and will not be changed unless selected."
            )
        }
        return plan
    }

    // MARK: - Resolution

    private struct ResolvedMethod {
        let id: JavaSymbolID
        let oldName: String
    }

    private static func resolveMethod(
        source: String, caretOffset: Int, url: URL, environment: JavaReferenceEnvironment
    ) async -> ResolvedMethod? {
        guard let tokenRange = identifierRange(at: caretOffset, in: source) else { return nil }
        guard let id = await JavaSymbolIdentity.symbolID(
            at: caretOffset, in: source, url: url, environment: environment
        ) else { return nil }
        if case .constructor = id { return nil }
        guard case .method = id else { return nil }
        let name = text(of: tokenRange, in: source)
        guard id.simpleName == name else { return nil }
        if let tree = JavaSyntaxParser().parse(source) {
            let byte = JavaNavigationText.utf8ByteOffset(forUTF16Offset: caretOffset, in: source)
            let node = tree.node(atByteOffset: byte)
            if let method = enclosingMethodDeclaration(of: node), hasVarargs(method) { return nil }
            if isAnnotationElement(node, in: tree) { return nil }
        }
        return ResolvedMethod(id: id, oldName: name)
    }

    private static func isAnnotationElement(_ node: SyntaxNode, in tree: JavaSyntaxTree) -> Bool {
        var current: SyntaxNode? = node
        while let next = current {
            if next.type == "annotation_type_element_declaration" { return true }
            if next.type == "method_declaration" || next.type == "method_invocation" { return false }
            current = next.parent
        }
        return false
    }

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

    // MARK: - Usages

    private static func collectUsages(
        _ targets: [JavaSymbolID], oldName: String, declaringFiles: [URL], documentURL: URL,
        candidates: any JavaUsageCandidateSource, roots: [URL], environment: JavaReferenceEnvironment
    ) async -> [JavaUsage] {
        let extra = declaringFiles + [documentURL.standardizedFileURL]
        let searchRoots = roots.isEmpty ? extra : roots
        var usages: [JavaUsage] = []
        var seenFiles = Set<String>()
        for target in targets {
            let found = await JavaUsageSearch.collect(
                target, candidates: candidates, roots: searchRoots, environment: environment, includeDeclarations: true
            )
            usages += found
            for usage in found { seenFiles.insert(usage.url.standardizedFileURL.path) }
        }
        for file in extra where seenFiles.insert(file.path).inserted {
            guard let text = await readText(of: file, environment: environment) else { continue }
            for target in targets {
                usages += await JavaFileUsageResolver.usages(of: target, source: text, url: file, environment: environment)
            }
        }
        var seen = Set<String>()
        return usages.filter { usage in
            let key = "\(usage.url.path):\(usage.byteRange.lowerBound)"
            return seen.insert(key).inserted
        }
    }

    private static func staticImportFiles(
        owners: [String], member: String, declaringFiles: [URL],
        candidates: any JavaUsageCandidateSource, roots: [URL], environment: JavaReferenceEnvironment
    ) async -> [URL] {
        let searchRoots = roots.isEmpty ? declaringFiles : roots
        var files = Set(await candidates.candidateFiles(containing: member, in: searchRoots).map(\.standardizedFileURL))
        for file in declaringFiles { files.insert(file) }
        var result: [URL] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let text = await readText(of: file, environment: environment), text.contains("import static") else { continue }
            result.append(file)
        }
        return result
    }

    // MARK: - AST edits

    private static func enclosingMethodDeclaration(of node: SyntaxNode) -> SyntaxNode? {
        var current: SyntaxNode? = node
        while let next = current {
            if next.type == "method_declaration" { return next }
            current = next.parent
        }
        return nil
    }

    private static func enclosingMethodInvocation(of node: SyntaxNode) -> SyntaxNode? {
        guard node.parent?.type == "method_invocation",
              node.parent?.child(byFieldName: "name")?.byteRange == node.byteRange else { return nil }
        return node.parent
    }

    private static func hasVarargs(_ method: SyntaxNode) -> Bool {
        guard let parameters = method.child(byFieldName: "parameters") else { return false }
        return parameters.namedChildren.contains { $0.type == "spread_parameter" }
    }

    static func rebuildFormalParameters(
        _ parameters: SyntaxNode, add: (type: String, name: String)?, removeLast: Bool
    ) -> String? {
        let formal = parameters.namedChildren.filter { $0.type == "formal_parameter" || $0.type == "spread_parameter" }
        if formal.contains(where: { $0.type == "spread_parameter" }) { return nil }
        var parts = formal.map(\.text)
        if removeLast { parts = Array(parts.dropLast()) }
        if let add { parts.append("\(add.type.trimmingCharacters(in: .whitespaces)) \(add.name)") }
        if parts.isEmpty { return "()" }
        return "(\(parts.joined(separator: ", ")))"
    }

    static func rebuildArgumentList(
        _ arguments: SyntaxNode, addDefault: String?, removeLast: Bool, oldArity: Int
    ) -> String? {
        let args = arguments.namedChildren
        var parts = args.map(\.text)
        if removeLast {
            guard !parts.isEmpty else { return nil }
            parts = Array(parts.dropLast())
        }
        if let addDefault {
            parts.append(addDefault.trimmingCharacters(in: .whitespaces))
        }
        if parts.isEmpty { return "()" }
        return "(\(parts.joined(separator: ", ")))"
    }

    // MARK: - Helpers

    private static func entry(
        url: URL, byteRange: Range<Int>, oldText: String, newText: String, source: String,
        description: String, ambiguous: Bool, readOnly: Bool
    ) -> WorkspaceEditPlanEntry {
        JavaRefactoringText.planEntry(
            url: url, byteRange: byteRange, oldText: oldText, newText: newText, source: source, description: description
        ).withFlags(ambiguous: ambiguous, readOnly: readOnly)
    }

    private static func readText(of file: URL, environment: JavaReferenceEnvironment) async -> String? {
        if let reader = environment.openBuffer, let text = await reader(file) { return text }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    private static func text(of byteRange: Range<Int>, in source: String) -> String {
        String(decoding: Array(source.utf8)[byteRange], as: UTF8.self)
    }

    private static func blocked(_ message: String) -> WorkspaceEditPlan {
        WorkspaceEditPlan(blockingError: message, title: title)
    }
}

private extension WorkspaceEditPlanEntry {
    func withFlags(ambiguous: Bool, readOnly: Bool) -> WorkspaceEditPlanEntry {
        WorkspaceEditPlanEntry(
            id: id, url: url, range: range, oldText: oldText, newText: newText, lineText: lineText,
            description: description, isAmbiguous: ambiguous, isReadOnly: readOnly
        )
    }
}
