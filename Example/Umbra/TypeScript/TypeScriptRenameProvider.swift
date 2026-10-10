import EditorIntelligence
import Foundation
import JavaIntelligence

/// Renames a local binding, and a resolved export along with the imports that name it.
/// An unresolved name, including a package import that does not point at a project file, is left alone
/// when the caret is on the imported module rather than a local binding.
struct TypeScriptRenameProvider: RenameProviding {
    private let cache: JavaDocumentParseCache
    private let index: TypeScriptIndex

    init(cache: JavaDocumentParseCache, index: TypeScriptIndex) {
        self.cache = cache
        self.index = index
    }

    func prepareRename(_ context: NavigationContext) async -> RenameTarget? {
        guard let target = await target(for: context) else { return nil }
        return RenameTarget(range: target.range, currentName: target.name, kindDescription: target.kind)
    }

    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan {
        guard let target = await target(for: context) else {
            return RenamePlan(blockingError: "Nothing to rename")
        }
        if let problem = RenameTarget.validateIdentifier(newName) {
            return RenamePlan(blockingError: problem)
        }
        var entries: [WorkspaceEditPlanEntry] = []
        var seen = Set<String>()
        func add(_ bytes: Range<Int>, text: TypeScriptText, url: URL) {
            let key = url.standardizedFileURL.path + ":\(bytes.lowerBound)"
            guard seen.insert(key).inserted else { return }
            entries.append(TypeScriptLocations.edit(
                bytes: bytes, text: text, url: url, oldName: target.name, newName: newName
            ))
        }
        if let url = context.document.url {
            add(target.binding.nameBytes, text: target.parsed.text, url: url)
            for use in target.parsed.model.uses where use.bindingStart == target.binding.nameBytes.lowerBound && use.name == target.binding.name && !use.isMemberProperty {
                add(use.bytes, text: target.parsed.text, url: url)
            }
        }
        if !target.exportNames.isEmpty, let file = context.document.url {
            let external = await index.externalUses(of: target.exportNames, definingFile: file)
            for fileUses in external {
                let text = TypeScriptText(fileUses.source)
                for range in fileUses.ranges {
                    add(range, text: text, url: fileUses.url)
                }
            }
        }
        return RenamePlan(entries: entries)
    }

    private struct Target {
        var parsed: TypeScriptParsed
        var binding: TypeScriptFileModel.Binding
        var range: EditorIntelligence.TextRange
        var name: String
        var kind: String
        var exportNames: [String]
    }

    private func target(for context: NavigationContext) async -> Target? {
        guard context.document.languageIdentifier == TypeScriptAnalysis.languageIdentifier else { return nil }
        guard let parsed = await TypeScriptAnalysis.parse(document: context.document, cache: cache) else { return nil }
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        guard let node = TypeScriptNames.name(atByte: byte, in: parsed.tree) else { return nil }
        if isUnresolvedImportedName(node) { return nil }
        guard let binding = binding(for: node, model: parsed.model) else { return nil }
        if binding.isImport, let specifier = binding.specifier, !specifier.hasPrefix("."),
           binding.nameBytes == node.byteRange, context.kind == .references {
            return nil
        }
        let declaration = parsed.model.declaration(matching: binding)
        let kind: String
        switch binding.symbolKind {
        case .function: kind = "function"
        case .method: kind = "method"
        case .class: kind = "class"
        case .interface: kind = "interface"
        case .enum: kind = "enum"
        case .typeAlias: kind = "type"
        case .namespace: kind = "namespace"
        case .parameter: kind = "parameter"
        case .local: kind = binding.isImport ? "import" : "variable"
        case .field: kind = "property"
        case .enumMember: kind = "enum member"
        }
        return Target(
            parsed: parsed, binding: binding, range: parsed.text.range(bytes: node.byteRange),
            name: binding.name, kind: kind, exportNames: declaration?.exportNames ?? []
        )
    }

    private func binding(for node: SyntaxNode, model: TypeScriptFileModel) -> TypeScriptFileModel.Binding? {
        if let binding = model.binding(atNameBytes: node.byteRange) { return binding }
        guard let use = model.uses.first(where: { $0.bytes == node.byteRange }),
              let start = use.bindingStart else { return nil }
        return model.binding(start: start, name: use.name)
    }

    /// `foo` in `import { foo as bar } from "pkg"` is not a local binding. A package specifier does not resolve.
    private func isUnresolvedImportedName(_ node: SyntaxNode) -> Bool {
        guard let parent = node.parent, parent.type == "import_specifier" || parent.type == "export_specifier" else { return false }
        guard parent.child(byFieldName: "alias") != nil, parent.child(byFieldName: "name")?.byteRange == node.byteRange else { return false }
        return true
    }
}
