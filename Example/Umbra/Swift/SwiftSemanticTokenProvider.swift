import EditorIntelligence
import Foundation

/// Identifier colours from the syntactic walk: declarations by kind, locals and parameters, and
/// calls. A name the file does not declare is left to the grammar's own colours.
struct SwiftSemanticTokenProvider: SemanticTokenProviding {
    func semanticHighlights(forSource source: String) async -> [SemanticHighlight]? {
        if Task.isCancelled { return nil }
        guard let parsed = SwiftAnalysis.parse(source) else { return nil }
        var tokens: [SemanticHighlight] = []
        var seen = Set<Int>()
        func add(bytes: Range<Int>, name: String?) {
            guard let name, !bytes.isEmpty, seen.insert(bytes.lowerBound).inserted else { return }
            let range = parsed.text.utf16Range(bytes: bytes)
            guard !range.isEmpty else { return }
            tokens.append(SemanticHighlight(range: range, highlightName: name))
        }

        // Names the file declares, by the one kind each has (an overloaded name of two kinds is skipped).
        var kinds: [String: String?] = [:]
        func walk(_ declaration: SwiftFileModel.Declaration) {
            let highlight = Self.highlight(declaration.kind)
            if declaration.kind != .extension, declaration.kind != .initializer {
                add(bytes: declaration.nameBytes, name: highlight)
                if let existing = kinds[declaration.name], existing != highlight {
                    kinds[declaration.name] = .some(nil)
                } else {
                    kinds[declaration.name] = highlight
                }
            }
            declaration.members.forEach(walk)
        }
        parsed.model.declarations.forEach(walk)

        for binding in parsed.model.bindings where !binding.nameBytes.isEmpty {
            switch binding.symbolKind {
            case .parameter, .local:
                add(bytes: binding.nameBytes, name: binding.symbolKind.highlightName)
            case .function, .type:
                break
            }
        }
        for use in parsed.model.uses {
            if Task.isCancelled { return nil }
            switch use.role {
            case .member:
                if use.isCall { add(bytes: use.bytes, name: "function.call") }
            case .implicitMember:
                break
            case .type:
                if let highlight = kinds[use.name] ?? nil, highlight.hasPrefix("type.") {
                    add(bytes: use.bytes, name: highlight)
                }
            case .value:
                if let binding = parsed.model.binding(named: use.name, at: use.bytes.lowerBound) {
                    switch binding.symbolKind {
                    case .parameter, .local: add(bytes: use.bytes, name: binding.symbolKind.highlightName)
                    case .function: add(bytes: use.bytes, name: use.isCall ? "function.call" : nil)
                    case .type: add(bytes: use.bytes, name: binding.symbolKind.highlightName)
                    }
                } else if use.isCall {
                    add(bytes: use.bytes, name: "function.call")
                } else if let highlight = kinds[use.name] ?? nil {
                    add(bytes: use.bytes, name: highlight)
                }
            }
        }
        tokens.sort { $0.range.lowerBound < $1.range.lowerBound }
        return tokens
    }

    private static func highlight(_ kind: SwiftFileModel.Kind) -> String? {
        switch kind {
        case .class, .struct, .actor, .typeAlias, .associatedType: return "type.class"
        case .protocol: return "type.interface"
        case .enum: return "type.enum"
        case .function, .subscript, .deinitializer: return "function.declaration"
        case .property: return "property"
        case .enumCase: return "constant.enum"
        case .initializer, .extension: return nil
        }
    }
}
