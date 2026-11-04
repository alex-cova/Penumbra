import EditorIntelligence
import Foundation

/// How LSP `SymbolKind` numbers (1...26) read in the editor's vocabulary (F26). A function-centric
/// language has no types to hang members on, so its `def`s and `fn`s are `function`s, not `method`s.
enum LSPSymbolKinds {
    static func structureKind(_ kind: Int) -> StructureKind {
        switch kind {
        case 5, 10, 11, 23, 26: .type           // class, enum, interface, struct, type parameter
        case 6: .method
        case 9: .constructor
        case 12, 25: .function                  // function, operator
        case 7, 8, 24: .field                   // property, field, event
        case 22: .enumConstant
        case 1, 2, 3, 4: .module                // file, module, namespace, package
        default: .variable                      // variable, constant, string, number, …
        }
    }

    static func hierarchyKind(_ kind: Int) -> HierarchyItemKind {
        switch kind {
        case 11: .interfaceType
        case 10: .enumType
        case 23: .structType
        case 6, 9: .method
        case 12, 25: .function
        default: .classType
        }
    }
}

/// An outline from `textDocument/documentSymbol`, for a language whose server offers one.
struct LSPReadyStructure: StructureProviding {
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    // Source alone cannot ask a server: the server needs the document's identity.
    func structure(forSource source: String, atUTF16Offset utf16Offset: Int) async -> StructureNode? { nil }
    func allStructure(forSource source: String) async -> [StructureNode]? { nil }

    func allStructure(forSource source: String, document: Document?) async -> [StructureNode]? {
        guard let document, languages.contains(document.languageIdentifier ?? ""), let client = connections.current,
              let symbols = try? await client.requestDocumentSymbolTree(for: document) else { return nil }
        let text = document.text
        let offsets = LineOffsets(text)
        return symbols.map { node(from: $0, parent: "", offsets: offsets) }
    }

    func structure(forSource source: String, document: Document?, atUTF16Offset utf16Offset: Int) async -> StructureNode? {
        guard let document, let roots = await allStructure(forSource: source, document: document), !roots.isEmpty else { return nil }
        // Like the Java outline: the innermost type around the caret, else the first one. A file with
        // no types (Python scripts, Go packages of functions) is outlined as a module of its symbols.
        func innermostType(in nodes: [StructureNode]) -> StructureNode? {
            for node in nodes where node.kind == .type && (node.bodyRange.contains(utf16Offset) || node.bodyRange.upperBound == utf16Offset) {
                return innermostType(in: node.children) ?? node
            }
            return nil
        }
        if let found = innermostType(in: roots) { return found }
        if let firstType = roots.first(where: { $0.kind == .type }) { return firstType }
        let title = document.displayName
        let whole = 0..<max(document.text.utf16.count, 1)
        return StructureNode(id: "module:\(title)", title: title, kind: .module, nameRange: 0..<0, bodyRange: whole, children: roots)
    }

    private func node(from symbol: LSPDocumentSymbol, parent: String, offsets: LineOffsets) -> StructureNode {
        let id = parent + "/" + symbol.name + "@\(symbol.selectionRange.start.line):\(symbol.selectionRange.start.character)"
        let name = offsets.range(symbol.selectionRange)
        let body = offsets.range(symbol.range)
        let title = symbol.detail.flatMap { $0.isEmpty ? nil : "\(symbol.name) \($0)" } ?? symbol.name
        return StructureNode(
            id: id, title: title, kind: LSPSymbolKinds.structureKind(symbol.kind),
            nameRange: name, bodyRange: body.lowerBound <= name.lowerBound && name.upperBound <= body.upperBound ? body : name.lowerBound..<max(body.upperBound, name.upperBound),
            children: symbol.children.map { node(from: $0, parent: id, offsets: offsets) }
        )
    }
}

/// LSP positions (line, UTF-16 character) as UTF-16 offsets into `text`. `\n`, `\r\n` and `\r` end a line.
struct LineOffsets {
    private var starts: [Int] = [0]
    private let length: Int

    init(_ text: String) {
        let units = Array(text.utf16)
        length = units.count
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 0x0D {
                if index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
                starts.append(index + 1)
            } else if unit == 0x0A {
                starts.append(index + 1)
            }
            index += 1
        }
    }

    func offset(_ position: LSPPosition) -> Int {
        guard position.line >= 0 else { return 0 }
        guard position.line < starts.count else { return length }
        return min(starts[position.line] + max(position.character, 0), length)
    }

    func range(_ range: LSPRange) -> Range<Int> {
        let lower = offset(range.start)
        return lower..<max(lower, offset(range.end))
    }
}
