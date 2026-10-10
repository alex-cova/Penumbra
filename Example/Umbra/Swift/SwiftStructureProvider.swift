import EditorIntelligence
import Foundation
import JavaIntelligence

/// Structure outline and breadcrumbs from the declarations of one file.
struct SwiftStructureProvider: StructureProviding, BreadcrumbProviding {
    func structure(forSource source: String, atUTF16Offset utf16Offset: Int) async -> StructureNode? {
        guard let parsed = SwiftAnalysis.parse(source) else { return nil }
        let match = innermostType(in: parsed.model.declarations, offset: utf16Offset, text: parsed.text)
            ?? parsed.model.declarations.first { $0.kind.isNominalType || $0.kind == .extension }
        return match.map { node(for: $0, text: parsed.text) }
    }

    func allStructure(forSource source: String) async -> [StructureNode]? {
        guard let parsed = SwiftAnalysis.parse(source) else { return nil }
        return parsed.model.declarations.map { node(for: $0, text: parsed.text) }
    }

    func breadcrumbs(for document: Document) async -> [BreadcrumbSegment]? {
        guard document.languageIdentifier == SwiftAnalysis.languageIdentifier else { return nil }
        guard !document.contentSnapshot.isElided, let parsed = SwiftAnalysis.parse(document.text) else { return [] }
        let offset = document.cursor.position.utf16Offset
        var chain: [SwiftFileModel.Declaration] = []
        func visit(_ declaration: SwiftFileModel.Declaration) {
            let full = parsed.text.utf16Range(bytes: declaration.fullBytes)
            guard full.contains(offset) || full.upperBound == offset else { return }
            chain.append(declaration)
            declaration.members.forEach(visit)
        }
        parsed.model.declarations.forEach(visit)
        return chain.map { declaration in
            BreadcrumbSegment(title: title(declaration), range: parsed.text.range(bytes: declaration.nameBytes))
        }
    }

    private func innermostType(
        in declarations: [SwiftFileModel.Declaration], offset: Int, text: SourceTextMap
    ) -> SwiftFileModel.Declaration? {
        var best: SwiftFileModel.Declaration?
        func visit(_ declaration: SwiftFileModel.Declaration) {
            let full = text.utf16Range(bytes: declaration.fullBytes)
            guard full.contains(offset) || full.upperBound == offset else { return }
            if declaration.kind.isNominalType || declaration.kind == .extension {
                if best == nil || declaration.fullBytes.count < best!.fullBytes.count { best = declaration }
            }
            declaration.members.forEach(visit)
        }
        declarations.forEach(visit)
        return best
    }

    private func node(for declaration: SwiftFileModel.Declaration, text: SourceTextMap) -> StructureNode {
        StructureNode(
            id: "\(declaration.kind.rawValue)-\(declaration.nameBytes.lowerBound)-\(declaration.name)",
            title: title(declaration),
            kind: structureKind(declaration.kind),
            nameRange: text.utf16Range(bytes: declaration.nameBytes),
            bodyRange: text.utf16Range(bytes: declaration.fullBytes),
            children: declaration.members.map { node(for: $0, text: text) }
        )
    }

    private func title(_ declaration: SwiftFileModel.Declaration) -> String {
        switch declaration.kind {
        case .extension:
            let conformances = declaration.inherits.isEmpty ? "" : ": " + declaration.inherits.joined(separator: ", ")
            return "extension \(declaration.name)\(conformances)"
        case .function, .initializer, .subscript:
            let labels = declaration.parameters.map { ($0.label ?? "_") + ":" }.joined()
            return "\(declaration.name)(\(labels))"
        case .property:
            return declaration.typeText.map { "\(declaration.name): \($0)" } ?? declaration.name
        default:
            return declaration.name
        }
    }

    private func structureKind(_ kind: SwiftFileModel.Kind) -> StructureKind {
        switch kind {
        case .function, .subscript, .deinitializer: return .method
        case .initializer: return .constructor
        case .property: return .field
        case .enumCase: return .enumConstant
        case .class, .struct, .enum, .actor, .protocol, .extension, .typeAlias, .associatedType: return .type
        }
    }
}
