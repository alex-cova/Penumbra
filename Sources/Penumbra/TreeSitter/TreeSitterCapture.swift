import Foundation

final class TreeSitterCapture {
    let node: TreeSitterNode
    let index: UInt32
    let name: String
    let byteRange: ByteRange
    let properties: [String: String]
    let textPredicates: [TreeSitterTextPredicate]
    let nameComponentCount: Int

    convenience init(node: TreeSitterNode, index: UInt32, name: String, predicates: [TreeSitterPredicate]) {
        self.init(
            node: node,
            index: index,
            name: name,
            byteRange: node.byteRange,
            mappedPredicates: TreeSitterPredicateMapper.map(predicates),
            nameComponentCount: name.split(separator: ".").count
        )
    }

    convenience init(
        node: TreeSitterNode,
        index: UInt32,
        name: String,
        mappedPredicates: TreeSitterPredicateMapper.MapResult,
        nameComponentCount: Int
    ) {
        self.init(
            node: node,
            index: index,
            name: name,
            byteRange: node.byteRange,
            mappedPredicates: mappedPredicates,
            nameComponentCount: nameComponentCount
        )
    }

    private init(
        node: TreeSitterNode,
        index: UInt32,
        name: String,
        byteRange: ByteRange,
        mappedPredicates: TreeSitterPredicateMapper.MapResult,
        nameComponentCount: Int
    ) {
        self.node = node
        self.index = index
        self.name = name
        self.byteRange = byteRange
        self.properties = mappedPredicates.properties
        self.textPredicates = mappedPredicates.textPredicates
        self.nameComponentCount = nameComponentCount
    }
}

extension TreeSitterCapture: CustomDebugStringConvertible {
    var debugDescription: String {
        "[TreeSitterCapture byteRange=\(byteRange) name=\(name) properties=\(properties) textPredicates=\(textPredicates)]"
    }
}
