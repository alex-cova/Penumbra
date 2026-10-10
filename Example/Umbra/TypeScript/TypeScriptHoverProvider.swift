import EditorIntelligence
import Foundation
import JavaIntelligence

/// Hover shows the declaration's text up to its body, plus a preceding `/** */` comment.
struct TypeScriptHoverProvider: HoverProvider {
    let name = TypeScriptAnalysis.providerName
    private let cache: JavaDocumentParseCache
    private let index: TypeScriptIndex

    init(cache: JavaDocumentParseCache, index: TypeScriptIndex) {
        self.cache = cache
        self.index = index
    }

    func provide(context: HoverContext) async -> HoverResult? {
        guard context.document.languageIdentifier == TypeScriptAnalysis.languageIdentifier else { return nil }
        guard let parsed = await TypeScriptAnalysis.parse(document: context.document, cache: cache) else { return nil }
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        guard let name = TypeScriptNames.name(atByte: byte, in: parsed.tree) else { return nil }
        if TypeScriptSite.inCommentOrString(name) { return nil }
        let signature = await signature(for: name, parsed: parsed, document: context.document)
        guard let signature, !signature.text.isEmpty else { return nil }
        var contents = "```ts\n\(signature.text)\n```"
        if let doc = signature.doc, !doc.isEmpty {
            contents += "\n\n" + doc
        }
        return HoverResult(contents: contents, range: parsed.text.range(bytes: name.byteRange), source: self.name)
    }

    private func signature(
        for node: SyntaxNode, parsed: TypeScriptParsed, document: Document
    ) async -> (text: String, doc: String?)? {
        if let binding = binding(for: node, model: parsed.model) {
            if binding.isImport, let specifier = binding.specifier, let imported = binding.importedName, let file = document.url,
               let target = await index.resolve(specifier: specifier, from: file),
               let resolved = await index.resolvedExport(named: imported, in: target) {
                return (resolved.declaration.signature, resolved.declaration.docComment)
            }
            if let declaration = parsed.model.declaration(matching: binding) {
                return (declaration.signature, declaration.docComment)
            }
            return (binding.signature, nil)
        }
        if let parent = node.parent, parent.type == "import_specifier" || parent.type == "export_specifier",
           parent.child(byFieldName: "name")?.byteRange == node.byteRange,
           let statement = importStatement(around: parent),
           let specifier = specifier(in: statement), let file = document.url,
           let target = await index.resolve(specifier: specifier, from: file),
           let resolved = await index.resolvedExport(named: node.text, in: target) {
            return (resolved.declaration.signature, resolved.declaration.docComment)
        }
        return nil
    }

    private func binding(for node: SyntaxNode, model: TypeScriptFileModel) -> TypeScriptFileModel.Binding? {
        if let binding = model.binding(atNameBytes: node.byteRange) { return binding }
        guard let use = model.uses.first(where: { $0.bytes == node.byteRange }),
              let start = use.bindingStart else { return nil }
        return model.binding(start: start, name: use.name)
    }

    private func importStatement(around node: SyntaxNode) -> SyntaxNode? {
        var current: SyntaxNode? = node
        while let next = current {
            if next.type == "import_statement" || next.type == "export_statement" { return next }
            current = next.parent
        }
        return nil
    }

    private func specifier(in node: SyntaxNode) -> String? {
        guard let source = node.child(byFieldName: "source") else { return nil }
        if let fragment = source.namedChildren.first(where: { $0.type == "string_fragment" }) {
            return fragment.text
        }
        var text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, let last = text.last, first == last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        return text.isEmpty ? nil : text
    }
}
