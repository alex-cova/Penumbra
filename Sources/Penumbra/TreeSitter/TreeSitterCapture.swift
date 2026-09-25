import Foundation

final class TreeSitterCapture {
    let node: TreeSitterNode
    let index: UInt32
    let name: String
    let byteRange: ByteRange
    let properties: [String: String]
    let textPredicates: [TreeSitterTextPredicate]
    let nameComponentCount: Int
    /// Index of the query pattern that produced this capture. Highlight queries list specific
    /// patterns before fallbacks (`(identifier) @variable` last), so on a tie the lower index wins.
    let patternIndex: UInt32

    convenience init(node: TreeSitterNode, index: UInt32, name: String, predicates: [TreeSitterPredicate]) {
        self.init(
            node: node,
            index: index,
            name: name,
            byteRange: node.byteRange,
            mappedPredicates: TreeSitterPredicateMapper.map(predicates),
            nameComponentCount: name.split(separator: ".").count,
            patternIndex: 0
        )
    }

    convenience init(
        node: TreeSitterNode,
        index: UInt32,
        name: String,
        mappedPredicates: TreeSitterPredicateMapper.MapResult,
        nameComponentCount: Int,
        patternIndex: UInt32
    ) {
        self.init(
            node: node,
            index: index,
            name: name,
            byteRange: node.byteRange,
            mappedPredicates: mappedPredicates,
            nameComponentCount: nameComponentCount,
            patternIndex: patternIndex
        )
    }

    private init(
        node: TreeSitterNode,
        index: UInt32,
        name: String,
        byteRange: ByteRange,
        mappedPredicates: TreeSitterPredicateMapper.MapResult,
        nameComponentCount: Int,
        patternIndex: UInt32
    ) {
        self.node = node
        self.index = index
        self.name = name
        self.byteRange = byteRange
        self.properties = mappedPredicates.properties
        self.textPredicates = mappedPredicates.textPredicates
        self.nameComponentCount = nameComponentCount
        self.patternIndex = patternIndex
    }
}

extension TreeSitterCapture: CustomDebugStringConvertible {
    var debugDescription: String {
        "[TreeSitterCapture byteRange=\(byteRange) name=\(name) properties=\(properties) textPredicates=\(textPredicates)]"
    }
}
