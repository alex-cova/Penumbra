import EditorIntelligence
import Foundation
import JavaIntelligence

/// Primary completion for TypeScript. Locals and imports are returned unfiltered; project exports
/// are prefiltered. A member access that cannot be resolved returns nothing, so word completion
/// stays out of `x.`.
struct TypeScriptCompletionProvider: CompletionProvider {
    let name = TypeScriptAnalysis.providerName
    private let cache: JavaDocumentParseCache
    private let index: TypeScriptIndex

    init(cache: JavaDocumentParseCache, index: TypeScriptIndex) {
        self.cache = cache
        self.index = index
    }

    func isPrimary(for context: CompletionContext) -> Bool {
        context.document.languageIdentifier == TypeScriptAnalysis.languageIdentifier
    }

    func provide(context: CompletionContext) async -> [CompletionItem] {
        guard isPrimary(for: context) else { return [] }
        guard let parsed = await TypeScriptAnalysis.parse(document: context.document, cache: cache) else { return [] }
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        switch TypeScriptSite.classify(byte: byte, tree: parsed.tree, isMemberAccess: context.isMemberAccess) {
        case .none:
            return []
        case .member(let node):
            return await memberItems(node, parsed: parsed, context: context, byte: byte)
        case .importExports(let specifier):
            return await importItems(specifier, parsed: parsed, context: context)
        case .type:
            return await scopedItems(parsed: parsed, context: context, byte: byte, typesOnly: true)
        case .value:
            return await scopedItems(parsed: parsed, context: context, byte: byte, typesOnly: false)
        }
    }

    private func memberItems(
        _ node: SyntaxNode, parsed: TypeScriptParsed, context: CompletionContext, byte: Int
    ) async -> [CompletionItem] {
        let object: SyntaxNode
        if node.type == "member_expression", let receiver = node.child(byFieldName: "object") {
            object = unwrap(receiver)
        } else if let receiver = receiverBeforeDot(at: byte, tree: parsed.tree) {
            // `x.` is an ERROR node until a property is typed. The receiver is the name before the dot.
            object = unwrap(receiver)
        } else {
            return []
        }
        if object.type == "member_expression" { return [] }
        if object.type == "this" {
            guard let className = enclosingClassName(node) else { return [] }
            let members = await collectMembers(
                named: className, model: parsed.model, file: context.document.url, at: object.startByte, allowPrivate: true
            )
            return members.map { memberItem($0, context: context) }
        }
        if object.type == "new_expression" || object.type == "as_expression" || object.type == "type_assertion" {
            guard let typeName = writtenType(of: object) else { return [] }
            let members = await collectMembers(
                named: typeName, model: parsed.model, file: context.document.url, at: object.startByte, allowPrivate: false
            )
            return members.map { memberItem($0, context: context) }
        }
        guard TypeScriptNames.isName(object.type) else { return [] }
        if let binding = parsed.model.binding(named: object.text, at: object.startByte) {
            if binding.isNamespaceImport, let specifier = binding.specifier, let file = context.document.url {
                return await moduleExports(specifier: specifier, from: file, context: context)
            }
            if let typeName = binding.typeName {
                let members = await collectMembers(
                    named: typeName, model: parsed.model, file: context.document.url, at: object.startByte, allowPrivate: false
                )
                return members.map { memberItem($0, context: context) }
            }
        }
        return []
    }

    private func importItems(_ specifier: String, parsed: TypeScriptParsed, context: CompletionContext) async -> [CompletionItem] {
        guard let file = context.document.url else { return [] }
        return await moduleExports(specifier: specifier, from: file, context: context)
    }

    private func scopedItems(
        parsed: TypeScriptParsed, context: CompletionContext, byte: Int, typesOnly: Bool
    ) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        var seen = Set<String>()
        let inScope = parsed.model.bindings.filter { $0.scopeStart <= byte && byte < $0.scopeEnd }
        let visible = Dictionary(grouping: inScope, by: \.name).compactMapValues { TypeScriptFileModel.innermost($0, at: byte) }
        for binding in visible.values {
            let include = typesOnly ? binding.isType : binding.isValue
            guard include, seen.insert(binding.name).inserted else { continue }
            items.append(item(
                label: binding.name,
                kind: completionKind(binding.symbolKind),
                detail: binding.typeName ?? binding.signature,
                priority: binding.isImport ? 20 : (binding.symbolKind == .parameter ? 28 : 30),
                edits: [],
                range: context.range
            ))
        }
        let exports = await index.exports(matching: context.prefix, limit: 100)
        for export in exports {
            if typesOnly {
                guard export.kind.isType else { continue }
            } else if export.isTypeOnly {
                continue
            }
            guard seen.insert(export.name).inserted else { continue }
            let edits = autoImport(name: export.name, from: export.url, document: context.document, parsed: parsed)
            items.append(item(
                label: export.name, kind: completionKind(export.kind), detail: export.signature,
                priority: 10, edits: edits, range: context.range
            ))
        }
        let keywords = typesOnly ? TypeScriptKeywords.types : TypeScriptKeywords.statements
        for keyword in keywords where seen.insert(keyword).inserted {
            items.append(item(
                label: keyword, kind: .keyword, detail: nil, priority: 0, edits: [], range: context.range
            ))
        }
        return items
    }

    private func moduleExports(specifier: String, from file: URL, context: CompletionContext) async -> [CompletionItem] {
        guard let target = await index.resolve(specifier: specifier, from: file),
              let model = await index.model(for: target) else { return [] }
        var items: [CompletionItem] = []
        var seen = Set<String>()
        for declaration in model.declarations where declaration.isTopLevel {
            for name in declaration.exportNames where name != "default" && seen.insert(name).inserted {
                items.append(item(
                    label: name, kind: completionKind(declaration.kind), detail: declaration.signature,
                    priority: 20, edits: [], range: context.range
                ))
            }
        }
        for reexport in model.reexports where reexport.exportedName != "default" && seen.insert(reexport.exportedName).inserted {
            items.append(item(
                label: reexport.exportedName, kind: .variable, detail: nil, priority: 20, edits: [], range: context.range
            ))
        }
        return items
    }

    private func collectMembers(
        named name: String, model: TypeScriptFileModel, file: URL?, at byte: Int, allowPrivate: Bool
    ) async -> [TypeScriptFileModel.Declaration] {
        var seen = Set<String>()
        var names = Set<String>()
        var result: [TypeScriptFileModel.Declaration] = []
        await appendMembers(
            named: name, model: model, file: file, at: byte, depth: 0, allowPrivate: allowPrivate,
            seen: &seen, names: &names, result: &result
        )
        return result
    }

    private func appendMembers(
        named name: String, model: TypeScriptFileModel, file: URL?, at byte: Int, depth: Int,
        allowPrivate: Bool, seen: inout Set<String>, names: inout Set<String>,
        result: inout [TypeScriptFileModel.Declaration]
    ) async {
        guard depth < 8, seen.insert(name).inserted else { return }
        guard let found = await lookupType(named: name, model: model, file: file, at: byte) else { return }
        for member in found.declaration.members where !member.name.hasPrefix("#") || allowPrivate {
            if member.isPrivate && !allowPrivate { continue }
            guard names.insert(member.name).inserted else { continue }
            result.append(member)
        }
        for heritage in found.declaration.heritage {
            await appendMembers(
                named: heritage, model: found.model, file: found.file, at: found.declaration.nameBytes.lowerBound,
                depth: depth + 1, allowPrivate: false, seen: &seen, names: &names, result: &result
            )
        }
    }

    private func lookupType(
        named name: String, model: TypeScriptFileModel, file: URL?, at byte: Int
    ) async -> (declaration: TypeScriptFileModel.Declaration, file: URL?, model: TypeScriptFileModel)? {
        if let binding = model.binding(named: name, at: byte), binding.isType,
           let declaration = model.declaration(matching: binding) {
            return (declaration, file, model)
        }
        if let declaration = model.topLevelDeclaration(named: name), declaration.kind.isType {
            return (declaration, file, model)
        }
        if let imported = model.imports.first(where: { $0.localName == name }),
           let file, let target = await index.resolve(specifier: imported.specifier, from: file),
           let resolved = await index.resolvedExport(named: imported.importedName, in: target),
           let targetModel = await index.model(for: resolved.url) {
            return (resolved.declaration, resolved.url, targetModel)
        }
        return nil
    }

    private func memberItem(_ member: TypeScriptFileModel.Declaration, context: CompletionContext) -> CompletionItem {
        item(
            label: member.name, kind: completionKind(member.kind), detail: member.typeName ?? member.signature,
            priority: 25, edits: [], range: context.range
        )
    }

    private func autoImport(
        name: String, from exportURL: URL, document: Document, parsed: TypeScriptParsed
    ) -> [TextEdit] {
        guard let file = document.url,
              let specifier = TypeScriptPaths.relativeSpecifier(from: file, to: exportURL) else { return [] }
        let statement = "import { \(name) } from \"\(specifier)\";"
        var lastImport: Int?
        for child in parsed.tree.rootNode.namedChildren where child.type == "import_statement" {
            lastImport = child.endByte
        }
        if let end = lastImport {
            let position = parsed.text.position(atByte: end)
            let range = EditorIntelligence.TextRange(start: position, end: position)
            return [TextEdit(range: range, replacement: "\n" + statement)]
        }
        var insert = 0
        if parsed.text.source.hasPrefix("#!"), let newline = parsed.text.source.firstIndex(of: "\n") {
            insert = parsed.text.source[parsed.text.source.startIndex...newline].utf8.count
        }
        let position = parsed.text.position(atByte: insert)
        let range = EditorIntelligence.TextRange(start: position, end: position)
        return [TextEdit(range: range, replacement: statement + "\n")]
    }

    private func item(
        label: String, kind: CompletionItemKind, detail: String?, priority: Double, edits: [TextEdit], range: EditorIntelligence.TextRange
    ) -> CompletionItem {
        CompletionItem(
            label: label, insertText: label, kind: kind, range: range, source: name,
            detail: detail, additionalEdits: edits, priority: priority
        )
    }

    private func completionKind(_ kind: TypeScriptFileModel.Kind) -> CompletionItemKind {
        switch kind {
        case .function: return .function
        case .method: return .method
        case .class: return .class
        case .interface: return .interface
        case .enum: return .enum
        case .typeAlias, .namespace: return .type
        case .field: return .field
        case .variable: return .variable
        case .enumMember: return .enumMember
        }
    }

    private func completionKind(_ kind: TypeScriptFileModel.SymbolKind) -> CompletionItemKind {
        switch kind {
        case .function: return .function
        case .method: return .method
        case .class: return .class
        case .interface: return .interface
        case .enum: return .enum
        case .typeAlias, .namespace: return .type
        case .parameter, .local: return .variable
        case .field: return .field
        case .enumMember: return .enumMember
        }
    }

    /// The caret sits on the character after `.`. The name is the token ending at that dot.
    private func receiverBeforeDot(at byte: Int, tree: JavaSyntaxTree) -> SyntaxNode? {
        guard byte > 0 else { return nil }
        guard let name = TypeScriptNames.name(atByte: byte - 1, in: tree) else { return nil }
        if let parent = name.parent, parent.type == "member_expression",
           parent.child(byFieldName: "property")?.startByte == name.startByte {
            return nil
        }
        return name
    }

    private func enclosingClassName(_ node: SyntaxNode) -> String? {
        var current = node.parent
        while let next = current {
            if next.type == "class_declaration" || next.type == "abstract_class_declaration" {
                return next.child(byFieldName: "name")?.text
            }
            current = next.parent
        }
        return nil
    }

    private func writtenType(of node: SyntaxNode) -> String? {
        let node = unwrap(node)
        switch node.type {
        case "new_expression":
            let constructor = node.child(byFieldName: "constructor") ?? node.namedChildren.first
            return constructor.flatMap { simpleName(unwrap($0)) }
        case "as_expression", "type_assertion":
            if let type = node.child(byFieldName: "type") { return simpleName(type) }
            return node.namedChildren.last.flatMap(simpleName)
        default:
            return nil
        }
    }

    private func simpleName(_ node: SyntaxNode) -> String? {
        switch node.type {
        case "identifier", "type_identifier":
            return node.text
        case "generic_type", "type_annotation", "parenthesized_type":
            if let name = node.child(byFieldName: "name") { return simpleName(name) }
            return node.namedChildren.first.flatMap(simpleName)
        default:
            return nil
        }
    }

    private func unwrap(_ node: SyntaxNode) -> SyntaxNode {
        var node = node
        for _ in 0..<8 {
            if node.type == "parenthesized_expression" || node.type == "non_null_expression",
               let inner = node.namedChildren.first {
                node = inner
                continue
            }
            return node
        }
        return node
    }
}
