import EditorIntelligence
import Foundation
import JavaIntelligence

/// Definition and usages for TypeScript. Implementation, type definition and super-method are
/// claimed (so the generic name index stays out) and unanswered: this engine does not infer types.
struct TypeScriptNavigationProvider: NavigationProvider {
    let name = TypeScriptAnalysis.providerName
    private let cache: JavaDocumentParseCache
    private let index: TypeScriptIndex

    init(cache: JavaDocumentParseCache, index: TypeScriptIndex) {
        self.cache = cache
        self.index = index
    }

    func isPrimary(for context: NavigationContext) -> Bool {
        context.document.languageIdentifier == TypeScriptAnalysis.languageIdentifier
    }

    func provide(context: NavigationContext) async -> NavigationResult? {
        guard isPrimary(for: context) else { return nil }
        switch context.kind {
        case .definition:
            guard let location = await definition(context) else { return nil }
            return .single(location)
        case .references:
            let locations = await references(context)
            return locations.isEmpty ? nil : .multiple(locations)
        case .implementation, .superMethod, .typeDefinition:
            return nil
        }
    }

    private func definition(_ context: NavigationContext) async -> Location? {
        guard let parsed = await TypeScriptAnalysis.parse(document: context.document, cache: cache) else { return nil }
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        guard let node = TypeScriptNames.name(atByte: byte, in: parsed.tree) else { return nil }
        if let imported = importedNameTarget(node, model: parsed.model), let file = context.document.url,
           let target = await index.resolve(specifier: imported.specifier, from: file),
           let resolved = await index.resolvedExport(named: imported.name, in: target),
           let source = await index.source(for: resolved.url) {
            let text = TypeScriptText(source)
            return TypeScriptLocations.make(
                bytes: resolved.declaration.nameBytes, text: text, document: context.document,
                file: resolved.url, name: resolved.declaration.name, kind: "declaration"
            )
        }
        guard let binding = binding(for: node, model: parsed.model) else { return nil }
        if binding.isImport, let specifier = binding.specifier, let imported = binding.importedName, let file = context.document.url,
           let target = await index.resolve(specifier: specifier, from: file),
           let resolved = await index.resolvedExport(named: imported, in: target),
           let source = await index.source(for: resolved.url) {
            let text = TypeScriptText(source)
            return TypeScriptLocations.make(
                bytes: resolved.declaration.nameBytes, text: text, document: context.document,
                file: resolved.url, name: resolved.declaration.name, kind: "declaration"
            )
        }
        return TypeScriptLocations.make(
            bytes: binding.nameBytes, text: parsed.text, document: context.document,
            file: context.document.url, name: binding.name, kind: "declaration"
        )
    }

    private func references(_ context: NavigationContext) async -> [Location] {
        guard let parsed = await TypeScriptAnalysis.parse(document: context.document, cache: cache) else { return [] }
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        guard let node = TypeScriptNames.name(atByte: byte, in: parsed.tree),
              let binding = binding(for: node, model: parsed.model) else { return [] }
        var locations = [TypeScriptLocations.make(
            bytes: binding.nameBytes, text: parsed.text, document: context.document,
            file: context.document.url, name: binding.name, kind: "declaration"
        )]
        for use in parsed.model.uses where use.bindingStart == binding.nameBytes.lowerBound && use.name == binding.name && !use.isMemberProperty {
            locations.append(TypeScriptLocations.make(
                bytes: use.bytes, text: parsed.text, document: context.document,
                file: context.document.url, name: use.name, kind: "reference"
            ))
        }
        if let declaration = parsed.model.declaration(matching: binding), !declaration.exportNames.isEmpty,
           let file = context.document.url {
            let external = await index.externalUses(of: declaration.exportNames, definingFile: file)
            for fileUses in external {
                let text = TypeScriptText(fileUses.source)
                for range in fileUses.ranges {
                    locations.append(TypeScriptLocations.make(
                        bytes: range, text: text, document: context.document, file: fileUses.url,
                        name: binding.name, kind: "reference"
                    ))
                }
            }
        }
        return locations
    }

    private func binding(for node: SyntaxNode, model: TypeScriptFileModel) -> TypeScriptFileModel.Binding? {
        if let binding = model.binding(atNameBytes: node.byteRange) { return binding }
        guard let use = model.uses.first(where: { $0.bytes == node.byteRange }),
              let start = use.bindingStart else { return nil }
        return model.binding(start: start, name: use.name)
    }

    /// `foo` in `import { foo as bar }` — the local binding is `bar`.
    private func importedNameTarget(_ node: SyntaxNode, model: TypeScriptFileModel) -> (name: String, specifier: String)? {
        guard let parent = node.parent, parent.type == "import_specifier" || parent.type == "export_specifier" else { return nil }
        guard parent.child(byFieldName: "name")?.byteRange == node.byteRange else { return nil }
        guard parent.child(byFieldName: "alias") != nil else { return nil }
        var current: SyntaxNode? = parent
        while let next = current {
            if next.type == "import_statement" || next.type == "export_statement" {
                guard let source = next.child(byFieldName: "source") else { return nil }
                let specifier: String
                if let fragment = source.namedChildren.first(where: { $0.type == "string_fragment" }) {
                    specifier = fragment.text
                } else {
                    specifier = source.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                return specifier.isEmpty ? nil : (node.text, specifier)
            }
            current = next.parent
        }
        return nil
    }
}
