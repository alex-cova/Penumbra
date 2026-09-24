import Foundation

/// Exact in-file usages of a local variable or parameter, from the scope chain
/// ``JavaSemanticWalker`` already keeps -- no index, no resolution.
public enum JavaLocalUsages {
    /// The declaration and every use of the local `id` names. Empty for any other kind of ID.
    public static func usages(of id: JavaSymbolID, in source: String) -> [JavaUsage] {
        guard case .local(let file, let declarationRange) = id,
              let tree = JavaSyntaxParser().parse(source) else { return [] }
        return usages(ofDeclaration: declarationRange, file: file, source: source, tree: tree)
    }

    static func usages(ofDeclaration declarationRange: Range<Int>, file: URL, source: String, tree: JavaSyntaxTree) -> [JavaUsage] {
        let walker = JavaSemanticWalker(tree: tree, source: source)
        var ranges: [(range: Range<Int>, isDeclaration: Bool)] = []
        walker.localSink = { declaration, identifier, isDeclaration in
            if declaration == declarationRange { ranges.append((identifier, isDeclaration)) }
        }
        guard walker.run() else { return [] }
        let locator = JavaUsageLocator(url: file, text: source)
        var seen = Set<Range<Int>>()
        return ranges.sorted { $0.range.lowerBound < $1.range.lowerBound }.compactMap { entry in
            guard seen.insert(entry.range).inserted else { return nil }
            let kind: JavaUsage.Kind
            if entry.isDeclaration {
                kind = .declaration
            } else {
                kind = isWrite(tree.node(inByteRange: entry.range)) ? .write : .read
            }
            return locator.usage(byteRange: entry.range, kind: kind, confidence: .exact)
        }
    }

    /// Whether the identifier is assigned to (`x = 1`, `x += 1`, `x++`) rather than only read.
    static func isWrite(_ node: SyntaxNode) -> Bool {
        var target = node
        if let parent = node.parent, parent.type == "field_access", parent.child(byFieldName: "field")?.byteRange == node.byteRange {
            target = parent
        }
        guard let parent = target.parent else { return false }
        switch parent.type {
        case "assignment_expression":
            return parent.child(byFieldName: "left")?.byteRange == target.byteRange
        case "update_expression":
            return true
        default:
            return false
        }
    }
}
