import EditorIntelligence
import Foundation

/// IntelliJ's "unresolved reference check" for inline suggestions, plus auto-import.
/// Implemented as an extension of the completion actor, so it shares its parse and index
/// state. The buffer is parsed through ``JavaCompletionProvider/parse(_:url:caching:)``,
/// which reuses the previous tree, and the suggestion is then reparsed on top of that
/// tree without replacing it. Identifier checks cover only the spliced range. Nothing
/// here is awaited on a keystroke.
extension JavaCompletionProvider: InlineCompletionValidating {
    public func validate(
        _ suggestion: InlineSuggestion, in document: Document, at position: TextPosition
    ) async -> InlineSuggestion? {
        guard document.languageIdentifier == "java" else { return suggestion }
        let original = JavaNavigationText.fullText(of: document)
        let url = document.url ?? URL(fileURLWithPath: "/unsaved/\(document.id).java")
        // Cache the real buffer first, so the suggestion reparse is an incremental edit on
        // that tree and a later completion still diffs from the document, not the ghost.
        guard parse(original, url: url) != nil else { return suggestion }
        let ns = original as NSString
        let caretUTF16 = min(max(0, position.utf16Offset), ns.length)
        let spliced = ns.substring(to: caretUTF16) + suggestion.text + ns.substring(from: caretUTF16)
        guard let parsed = parse(spliced, url: url, caching: false) else { return suggestion }
        let splicedTree = parsed.tree
        let stubs = parsed.stubs
        let caretByte = Self.utf8ByteOffset(forUTF16Offset: caretUTF16, in: spliced)
        let suggestionBytes = Array(suggestion.text.utf8)
        // Reject when the spliced range itself parses with errors. (The buffer around
        // the caret is usually incomplete too, so only the suggestion's own range counts.
        // Missing closers are not errors here; the formatter appends them beforehand.)
        if Self.hasErrorNode(in: splicedTree.rootNode, within: caretByte..<(caretByte + suggestionBytes.count)) {
            return nil
        }
        let context = Self.resolutionContext(in: splicedTree, fileStubs: stubs, atByteOffset: caretByte)
        let importer = JavaImportInserter(
            text: spliced, bytes: Array(spliced.utf8), tree: splicedTree, fileStubs: stubs,
            policy: .intellij
        )
        let locals = Set(JavaLocalScope.locals(in: splicedTree, atByteOffset: caretByte).map(\.name))
        let declaredNames = Set(stubs.classes.flatMap { stub in
            [stub.simpleName] + stub.methods.map(\.name) + stub.fields.map(\.name)
        })
        let importedNames = Set(stubs.imports.map { $0.qualifiedName.split(separator: ".").last.map(String.init) ?? $0.qualifiedName })
        let implicitNames = await implicitMemberNames(context: context, stubs: stubs, tree: splicedTree, caretByte: caretByte)
        let staticImportNames = Set((await JavaStaticImports.members(context: context, index: javaIndex)).map(\.name))

        var additionalEdits = suggestion.additionalEdits
        for node in Self.identifierNodes(in: splicedTree.rootNode, within: caretByte..<(caretByte + suggestionBytes.count)) {
            let name = node.text
            guard !name.isEmpty, name != Self.dummyIdentifier else { continue }
            if await isResolved(
                node, name: name, spliced: spliced, tree: splicedTree, context: context,
                locals: locals, declaredNames: declaredNames, importedNames: importedNames,
                implicitNames: implicitNames, staticImportNames: staticImportNames,
                importer: importer, additionalEdits: &additionalEdits
            ) { continue }
            // First unresolved identifier: truncate the suggestion before it.
            let cutByte = node.startByte - caretByte
            guard cutByte > 0 else { return nil }
            let truncated = String(decoding: suggestionBytes[0..<cutByte], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let nonSpace = truncated.filter { !$0.isWhitespace }
            guard nonSpace.count >= 2 else { return nil }
            return InlineSuggestion(text: truncated, additionalEdits: additionalEdits)
        }
        return InlineSuggestion(text: suggestion.text, additionalEdits: additionalEdits)
    }

    /// Names reachable without a receiver: members of the enclosing types (inherited ones
    /// included), static-only when the caret is in a static method or initializer.
    private func implicitMemberNames(
        context: JavaResolutionContext, stubs: JavaSourceFileStubs, tree: JavaSyntaxTree, caretByte: Int
    ) async -> Set<String> {
        let mode: JavaMemberLookupMode = Self.isStaticContext(tree: tree, offset: caretByte) ? .staticOnly : .instance
        var names = Set<String>()
        for enclosing in context.enclosingTypeQualifiedNames {
            if await javaIndex.classStub(qualifiedName: enclosing) != nil {
                let type = JavaTypeRef.classType(qualifiedName: enclosing, arguments: [], outer: nil)
                let members = await JavaMemberLookup.members(
                    of: type, mode: mode, context: context, index: javaIndex, checkAccess: true
                )
                names.formUnion(members.map(\.name))
                continue
            }
            // The file is not in the index yet. Its own members are already in the declared-name
            // set; walk the supertypes written on the file stub, with Object when none is.
            guard let stub = stubs.classes.first(where: { $0.qualifiedName == enclosing }) else { continue }
            var supertypes: [JavaTypeRef] = []
            if let superclass = stub.superclass {
                supertypes.append(superclass)
            } else if stub.kind == .classKind || stub.kind == .enumKind || stub.kind == .recordKind {
                supertypes.append(.classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil))
            }
            supertypes.append(contentsOf: stub.interfaces)
            for supertype in supertypes {
                let resolved = await JavaTypeResolver.resolve(supertype, context: context, index: javaIndex)
                let members = await JavaMemberLookup.members(
                    of: resolved, mode: mode, context: context, index: javaIndex, checkAccess: true
                )
                names.formUnion(members.map(\.name))
            }
        }
        return names
    }

    private func isResolved(
        _ node: SyntaxNode, name: String, spliced: String, tree: JavaSyntaxTree,
        context: JavaResolutionContext, locals: Set<String>, declaredNames: Set<String>,
        importedNames: Set<String>, implicitNames: Set<String>, staticImportNames: Set<String>,
        importer: JavaImportInserter, additionalEdits: inout [TextEdit]
    ) async -> Bool {
        // A member name on a receiver: type the receiver and look the member up.
        if let parent = node.parent, parent.type == "method_invocation" || parent.type == "field_access",
           let object = parent.child(byFieldName: "object"), object.endByte <= node.startByte {
            let bytes = Array(spliced.utf8)
            var dot = object.endByte
            while dot < node.startByte, bytes[dot] != UInt8(ascii: ".") { dot += 1 }
            guard dot < node.startByte,
                  let receiver = await JavaExpressionTyper.receiverInfo(
                      source: spliced, realTree: tree, dotOffset: dot, context: context, index: javaIndex
                  ), receiver.packageName == nil else { return false }
            let members = await JavaMemberLookup.members(
                of: receiver.type, mode: receiver.isTypeReference ? .staticOnly : .instance,
                context: context, index: javaIndex, checkAccess: false
            )
            return members.contains { $0.name == name }
        }
        if locals.contains(name) || declaredNames.contains(name) || importedNames.contains(name)
            || implicitNames.contains(name) || staticImportNames.contains(name) {
            return true
        }
        // A type name: already in scope (same package, `java.lang`, an import), or exactly one
        // indexed class, which is then auto-imported on accept.
        let isTypeName = node.type == "type_identifier" || name.first?.isUppercase == true
        if isTypeName {
            let matches = await javaIndex.classes(simpleName: name, limit: 3)
            if matches.contains(where: { Self.typeIsInScope($0, context: context) }) {
                return true
            }
            if matches.count == 1, let stub = matches.first {
                switch importer.decision(for: stub) {
                case .none, .useQualifiedName: return true
                case .addImport(let edit):
                    additionalEdits.append(edit)
                    return true
                }
            }
            return matches.isEmpty ? false : true
        }
        return false
    }

    /// Same package, `java.lang`, a single-type import, or an on-demand import of the package.
    private static func typeIsInScope(_ stub: JavaClassStub, context: JavaResolutionContext) -> Bool {
        if stub.packageName == context.packageName || stub.packageName == "java.lang" { return true }
        for declaration in context.imports where !declaration.isStatic {
            if declaration.isOnDemand {
                if declaration.qualifiedName == (stub.outerQualifiedName ?? stub.packageName) { return true }
            } else if declaration.qualifiedName == stub.qualifiedName {
                return true
            }
        }
        return false
    }

    /// Identifier nodes (uses, not declaration names where avoidable) inside `range`,
    /// in source order.
    static func identifierNodes(in node: SyntaxNode, within range: Range<Int>) -> [SyntaxNode] {
        var result: [SyntaxNode] = []
        func walk(_ node: SyntaxNode) {
            if node.type == "identifier" || node.type == "type_identifier",
               range.contains(node.startByte), node.endByte <= range.upperBound {
                result.append(node)
            }
            for child in node.children { walk(child) }
        }
        walk(node)
        return result
    }

    static func hasErrorNode(in node: SyntaxNode, within range: Range<Int>) -> Bool {
        // A missing closer is not a reason to drop the suggestion; the formatter inserts those.
        if node.isMissing { return false }
        if node.type == "ERROR", node.startByte < range.upperBound, node.endByte > range.lowerBound {
            return true
        }
        return node.children.contains { hasErrorNode(in: $0, within: range) }
    }
}
