import EditorIntelligence
import Foundation

/// Structure outline and breadcrumbs from the top-level declarations of one file.
struct TypeScriptStructureProvider: StructureProviding, BreadcrumbProviding {
    func structure(forSource source: String, atUTF16Offset utf16Offset: Int) async -> StructureNode? {
        guard let parsed = TypeScriptAnalysis.parse(source) else { return nil }
        let match = innermostType(in: parsed.model.declarations, offset: utf16Offset, text: parsed.text)
            ?? parsed.model.declarations.first { $0.kind.isType }
        return match.map { node(for: $0, text: parsed.text) }
    }

    func allStructure(forSource source: String) async -> [StructureNode]? {
        guard let parsed = TypeScriptAnalysis.parse(source) else { return nil }
        return parsed.model.declarations.map { node(for: $0, text: parsed.text) }
    }

    func breadcrumbs(for document: Document) async -> [BreadcrumbSegment]? {
        guard document.languageIdentifier == TypeScriptAnalysis.languageIdentifier else { return nil }
        guard !document.contentSnapshot.isElided, let parsed = TypeScriptAnalysis.parse(document.text) else { return [] }
        let offset = document.cursor.position.utf16Offset
        var chain: [TypeScriptFileModel.Declaration] = []
        func visit(_ declaration: TypeScriptFileModel.Declaration) {
            let body = parsed.text.utf16Range(bytes: declaration.bodyBytes)
            guard body.contains(offset) || body.upperBound == offset else { return }
            chain.append(declaration)
            declaration.members.forEach(visit)
        }
        parsed.model.declarations.forEach(visit)
        return chain.map { declaration in
            BreadcrumbSegment(title: declaration.name, range: parsed.text.range(bytes: declaration.nameBytes))
        }
    }

    private func innermostType(
        in declarations: [TypeScriptFileModel.Declaration], offset: Int, text: TypeScriptText
    ) -> TypeScriptFileModel.Declaration? {
        var best: TypeScriptFileModel.Declaration?
        func visit(_ declaration: TypeScriptFileModel.Declaration) {
            let body = text.utf16Range(bytes: declaration.bodyBytes)
            guard body.contains(offset) || body.upperBound == offset else { return }
            if declaration.kind.isType {
                if best == nil || declaration.bodyBytes.count < best!.bodyBytes.count {
                    best = declaration
                }
            }
            declaration.members.forEach(visit)
        }
        declarations.forEach(visit)
        return best
    }

    private func node(for declaration: TypeScriptFileModel.Declaration, text: TypeScriptText) -> StructureNode {
        StructureNode(
            id: "\(declaration.kind)-\(declaration.nameBytes.lowerBound)-\(declaration.name)",
            title: declaration.name,
            kind: structureKind(declaration.kind),
            nameRange: text.utf16Range(bytes: declaration.nameBytes),
            bodyRange: text.utf16Range(bytes: declaration.bodyBytes),
            children: declaration.members.map { node(for: $0, text: text) }
        )
    }

    private func structureKind(_ kind: TypeScriptFileModel.Kind) -> StructureKind {
        switch kind {
        case .function, .method: return .method
        case .field, .variable: return .field
        case .enumMember: return .enumConstant
        case .class, .interface, .typeAlias, .enum, .namespace: return .type
        }
    }
}
