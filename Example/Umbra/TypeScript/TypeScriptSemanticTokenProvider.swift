import EditorIntelligence
import Foundation

/// Identifier colours from the syntactic walk. Unresolved names and predefined types are left to the grammar.
struct TypeScriptSemanticTokenProvider: SemanticTokenProviding {
    func semanticHighlights(forSource source: String) async -> [SemanticHighlight]? {
        if Task.isCancelled { return nil }
        guard let parsed = TypeScriptAnalysis.parse(source) else { return nil }
        var tokens: [SemanticHighlight] = []
        var seen = Set<Int>()
        func add(bytes: Range<Int>, name: String?) {
            guard let name, !bytes.isEmpty, seen.insert(bytes.lowerBound).inserted else { return }
            let range = parsed.text.utf16Range(bytes: bytes)
            guard !range.isEmpty else { return }
            tokens.append(SemanticHighlight(range: range, highlightName: name))
        }
        func walk(_ declaration: TypeScriptFileModel.Declaration) {
            add(bytes: declaration.nameBytes, name: highlight(declaration.kind))
            declaration.members.forEach(walk)
        }
        parsed.model.declarations.forEach(walk)
        for binding in parsed.model.bindings where !binding.isImport {
            switch binding.symbolKind {
            case .parameter, .local:
                add(bytes: binding.nameBytes, name: binding.symbolKind.highlightName)
            default:
                break
            }
        }
        for use in parsed.model.uses {
            if use.isCall {
                add(bytes: use.bytes, name: "function.call")
                continue
            }
            if use.isMemberProperty { continue }
            guard let start = use.bindingStart, let binding = parsed.model.binding(start: start, name: use.name) else { continue }
            switch binding.symbolKind {
            case .function, .method:
                break
            case .class, .interface, .enum, .typeAlias, .namespace, .parameter, .local, .field, .enumMember:
                add(bytes: use.bytes, name: binding.symbolKind.highlightName)
            }
        }
        tokens.sort { $0.range.lowerBound < $1.range.lowerBound }
        return tokens
    }

    private func highlight(_ kind: TypeScriptFileModel.Kind) -> String? {
        switch kind {
        case .class, .typeAlias, .namespace: return "type.class"
        case .interface: return "type.interface"
        case .enum: return "type.enum"
        case .function, .method: return "function.declaration"
        case .field: return "property"
        case .variable: return "variable.local"
        case .enumMember: return "constant.enum"
        }
    }
}
