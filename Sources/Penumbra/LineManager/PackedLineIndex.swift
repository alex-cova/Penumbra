import CoreGraphics
import Foundation

struct PackedLeafID: RedBlackTreeNodeID, Hashable {
    let id = UUID()
    init() {}
}

struct PackedLine {
    var id: UInt32
    var utf16Length: UInt32
    var delimiterLength: UInt8
    var height: Float32
}

final class PackedLeafData {
    static let capacity = 64

    var lines: [PackedLine]
    var nodeTotalLineCount = 0
    var totalLineHeight: CGFloat = 0
    var nodeTotalByteCount = ByteCount(0)

    var utf16Sum: Int {
        lines.reduce(0) { $0 + Int($1.utf16Length) }
    }

    var heightSum: CGFloat {
        lines.reduce(0) { $0 + CGFloat($1.height) }
    }

    init(lines: [PackedLine]) {
        self.lines = lines
        nodeTotalLineCount = lines.count
        totalLineHeight = heightSum
        nodeTotalByteCount = ByteCount(utf16Length: utf16Sum)
    }
}

final class PackedLeafChildrenUpdater: RedBlackTreeChildrenUpdater<PackedLeafID, Int, PackedLeafData> {
    override func updateAfterChangingChildren(of node: Node) -> Bool {
        var lineCount = node.data.lines.count
        var totalHeight = node.data.heightSum
        var totalBytes = ByteCount(utf16Length: node.data.utf16Sum)
        if let leftNode = node.left {
            lineCount += leftNode.data.nodeTotalLineCount
            totalHeight += leftNode.data.totalLineHeight
            totalBytes += leftNode.data.nodeTotalByteCount
        }
        if let rightNode = node.right {
            lineCount += rightNode.data.nodeTotalLineCount
            totalHeight += rightNode.data.totalLineHeight
            totalBytes += rightNode.data.nodeTotalByteCount
        }
        if lineCount != node.data.nodeTotalLineCount
            || totalHeight != node.data.totalLineHeight
            || totalBytes != node.data.nodeTotalByteCount {
            node.data.nodeTotalLineCount = lineCount
            node.data.totalLineHeight = totalHeight
            node.data.nodeTotalByteCount = totalBytes
            return true
        }
        return false
    }
}

typealias PackedLeafTree = RedBlackTree<PackedLeafID, Int, PackedLeafData>
typealias PackedLeafNode = RedBlackTreeNode<PackedLeafID, Int, PackedLeafData>

/// Order-statistics tree of fat leaves (~64 lines each). Per-line storage is a `PackedLine` record,
/// not a heap object, so short-line files do not pay 160–220 bytes/line of RB-tree nodes.
final class PackedLineIndex {
    private let tree: PackedLeafTree
    private var nextID: UInt32 = 1
    var estimatedLineHeight: CGFloat
    private(set) var longestRow = 0
    private var streamingPacked: [[PackedLine]] = []
    private var streamingCurrent: [PackedLine] = []
    private var streamingRow = 0

    var lineCount: Int {
        tree.root.data.nodeTotalLineCount
    }

    var utf16Length: Int {
        tree.root.nodeTotalValue
    }

    var contentHeight: CGFloat {
        tree.root.data.totalLineHeight
    }

    init(estimatedLineHeight: CGFloat) {
        self.estimatedLineHeight = estimatedLineHeight
        let empty = PackedLine(id: 0, utf16Length: 0, delimiterLength: 0, height: Float32(estimatedLineHeight))
        let data = PackedLeafData(lines: [empty])
        tree = PackedLeafTree(minimumValue: 0, rootValue: 0, rootData: data)
        tree.childrenUpdater = PackedLeafChildrenUpdater()
        data.nodeTotalLineCount = 1
        data.totalLineHeight = estimatedLineHeight
        data.nodeTotalByteCount = ByteCount(0)
        tree.root.value = 0
    }

    func rebuild(from metrics: [LineMetric], estimatedLineHeight: CGFloat) {
        prepareStreamingRebuild(estimatedLineHeight: estimatedLineHeight)
        let metrics = metrics.isEmpty ? [LineMetric(totalLength: 0, delimiterLength: 0)] : metrics
        for metric in metrics {
            appendStreamingLine(utf16Length: metric.totalLength, delimiterLength: metric.delimiterLength)
        }
        finishStreamingRebuild()
    }

    func prepareStreamingRebuild(estimatedLineHeight: CGFloat) {
        self.estimatedLineHeight = estimatedLineHeight
        // `nextID` is deliberately NOT reset here. `DocumentLineNodeID` is a bare `UInt32` counter
        // (not the UUID it once was), and callers key long-lived caches on it — `LineController`s,
        // cached line widths, reused line-number / line-fragment views. If a rebuild handed out
        // `1, 2, 3, …` again, those caches would resurrect the previous document's lines. Keeping
        // the counter monotonic for the life of this index guarantees a rebuilt line never
        // collides with one from before the rebuild. (`&+` wraps after 2^32 lines' worth of
        // rebuilds, astronomically beyond any session; the wrapped value is still internally
        // consistent.)
        longestRow = 0
        longestUTF16DuringStream = 0
        streamingRow = 0
        streamingPacked = []
        streamingCurrent = []
        streamingCurrent.reserveCapacity(PackedLeafData.capacity)
    }

    func appendStreamingLine(utf16Length: Int, delimiterLength: Int) {
        if utf16Length > longestUTF16DuringStream {
            longestUTF16DuringStream = utf16Length
            longestRow = streamingRow
        }
        streamingCurrent.append(PackedLine(
            id: nextID,
            utf16Length: UInt32(utf16Length),
            delimiterLength: UInt8(clamping: delimiterLength),
            height: Float32(estimatedLineHeight)
        ))
        nextID &+= 1
        streamingRow += 1
        if streamingCurrent.count == PackedLeafData.capacity {
            streamingPacked.append(streamingCurrent)
            streamingCurrent = []
            streamingCurrent.reserveCapacity(PackedLeafData.capacity)
        }
    }

    func finishStreamingRebuild() {
        if streamingPacked.isEmpty && streamingCurrent.isEmpty {
            appendStreamingLine(utf16Length: 0, delimiterLength: 0)
        }
        if !streamingCurrent.isEmpty {
            streamingPacked.append(streamingCurrent)
            streamingCurrent = []
        }
        var leaves: [PackedLeafNode] = []
        leaves.reserveCapacity(streamingPacked.count)
        for packed in streamingPacked {
            let data = PackedLeafData(lines: packed)
            leaves.append(PackedLeafNode(tree: tree, value: data.utf16Sum, data: data))
        }
        streamingPacked = []
        tree.rebuild(from: leaves)
        longestUTF16DuringStream = 0
    }

    private var longestUTF16DuringStream = 0

    func line(atRow row: Int) -> PackedLine {
        let (leaf, slot, _) = locate(row: row)
        return leaf.data.lines[slot]
    }

    func location(ofRow row: Int) -> Int {
        let found = locate(row: row)
        return found.utf16Start + slotUTF16Prefix(leaf: found.leaf, slot: found.slot)
    }

    func yPosition(ofRow row: Int) -> CGFloat {
        let (leaf, slot, _) = locate(row: row)
        return yPosition(of: leaf) + slotHeightPrefix(leaf: leaf, slot: slot)
    }

    func startByte(ofRow row: Int) -> ByteCount {
        ByteCount(utf16Length: location(ofRow: row))
    }

    func row(containingUTF16 location: Int) -> Int? {
        guard location >= 0, location <= tree.root.nodeTotalValue else {
            return nil
        }
        guard let leaf = tree.node(containingLocation: location) else {
            return nil
        }
        var local = location - leaf.location
        let rowBase = lineIndex(of: leaf)
        for slot in 0..<leaf.data.lines.count {
            let length = Int(leaf.data.lines[slot].utf16Length)
            if local < length || (slot == leaf.data.lines.count - 1 && local <= length) {
                return rowBase + slot
            }
            local -= length
        }
        return max(0, lineCount - 1)
    }

    func row(containingYOffset yOffset: CGFloat) -> Int? {
        guard lineCount > 0 else {
            return nil
        }
        // Layout queries `paddedInsetViewport.minY`, which is negative (~-350pt padding).
        // Clamp rather than returning nil — a nil start line skips the entire viewport walk.
        let height = max(contentHeight, 0)
        let clamped = min(max(yOffset, 0), height)
        guard let leaf = tree.node(
            containingLocation: clamped,
            minimumValue: 0,
            valueKeyPath: \.data.heightSum,
            totalValueKeyPath: \.data.totalLineHeight
        ) else {
            return nil
        }
        var y = yPosition(of: leaf)
        let rowBase = lineIndex(of: leaf)
        for slot in 0..<leaf.data.lines.count {
            let slotHeight = CGFloat(leaf.data.lines[slot].height)
            if clamped < y + slotHeight || slot == leaf.data.lines.count - 1 {
                return rowBase + slot
            }
            y += slotHeight
        }
        return rowBase
    }

    func row(containingByte byteIndex: ByteCount) -> Int? {
        row(containingUTF16: byteIndex.utf16Length)
    }

    @discardableResult
    func setHeight(row: Int, to newHeight: CGFloat) -> Bool {
        let (leaf, slot, _) = locate(row: row)
        if abs(CGFloat(leaf.data.lines[slot].height) - newHeight) < CGFloat.ulpOfOne {
            return false
        }
        leaf.data.lines[slot].height = Float32(newHeight)
        tree.updateAfterChangingChildren(of: leaf)
        return true
    }

    func setLength(row: Int, utf16Length: Int, delimiterLength: Int) {
        let (leaf, slot, _) = locate(row: row)
        leaf.data.lines[slot].utf16Length = UInt32(utf16Length)
        leaf.data.lines[slot].delimiterLength = UInt8(clamping: delimiterLength)
        leaf.value = leaf.data.utf16Sum
        tree.updateAfterChangingChildren(of: leaf)
    }

    func insertLine(afterRow row: Int, utf16Length: Int, delimiterLength: Int) -> UInt32 {
        let id = nextID
        nextID &+= 1
        let (leaf, slot, _) = locate(row: row)
        let line = PackedLine(
            id: id,
            utf16Length: UInt32(utf16Length),
            delimiterLength: UInt8(clamping: delimiterLength),
            height: Float32(estimatedLineHeight)
        )
        let insertAt = slot + 1
        if leaf.data.lines.count < PackedLeafData.capacity {
            leaf.data.lines.insert(line, at: insertAt)
            leaf.value = leaf.data.utf16Sum
            tree.updateAfterChangingChildren(of: leaf)
        } else {
            var all = leaf.data.lines
            all.insert(line, at: insertAt)
            let mid = all.count / 2
            leaf.data.lines = Array(all[..<mid])
            leaf.value = leaf.data.utf16Sum
            let newData = PackedLeafData(lines: Array(all[mid...]))
            let newNode = tree.insertNode(value: newData.utf16Sum, data: newData, after: leaf)
            tree.updateAfterChangingChildren(of: leaf)
            tree.updateAfterChangingChildren(of: newNode)
        }
        return id
    }

    func removeLine(atRow row: Int) -> UInt32 {
        let (leaf, slot, _) = locate(row: row)
        let id = leaf.data.lines[slot].id
        leaf.data.lines.remove(at: slot)
        if leaf.data.lines.isEmpty {
            if lineCount > 1 {
                tree.remove(leaf)
            } else {
                leaf.data.lines = [
                    PackedLine(id: nextID, utf16Length: 0, delimiterLength: 0, height: Float32(estimatedLineHeight))
                ]
                nextID &+= 1
                leaf.value = 0
                tree.updateAfterChangingChildren(of: leaf)
            }
        } else {
            leaf.value = leaf.data.utf16Sum
            tree.updateAfterChangingChildren(of: leaf)
        }
        return id
    }

    func dataSnapshot(atRow row: Int, location: Int, estimatedFallbackHeight: CGFloat) -> DocumentLineNodeData {
        let line = line(atRow: row)
        let data = DocumentLineNodeData(lineHeight: CGFloat(line.height))
        data.totalLength = Int(line.utf16Length)
        data.delimiterLength = Int(line.delimiterLength)
        data.lineHeight = CGFloat(line.height)
        data.byteCount = ByteCount(utf16Length: Int(line.utf16Length))
        data.cachedStartByte = ByteCount(utf16Length: location)
        return data
    }

    private func locate(row: Int) -> (leaf: PackedLeafNode, slot: Int, utf16Start: Int) {
        let capped = min(max(row, 0), max(lineCount - 1, 0))
        var remaining = capped
        var node = tree.root!
        var utf16Before = 0
        while true {
            if let left = node.left, remaining < left.data.nodeTotalLineCount {
                node = left
                continue
            }
            if let left = node.left {
                remaining -= left.data.nodeTotalLineCount
                utf16Before += left.nodeTotalValue
            }
            if remaining < node.data.lines.count {
                return (node, remaining, utf16Before)
            }
            remaining -= node.data.lines.count
            utf16Before += node.value
            if let right = node.right {
                node = right
            } else {
                let slot = max(node.data.lines.count - 1, 0)
                return (node, slot, utf16Before - node.value)
            }
        }
    }

    private func lineIndex(of leaf: PackedLeafNode) -> Int {
        var index = leaf.left?.data.nodeTotalLineCount ?? 0
        var working = leaf
        while let parent = working.parent {
            if working === parent.right {
                if let left = parent.left {
                    index += left.data.nodeTotalLineCount
                }
                index += parent.data.lines.count
            }
            working = parent
        }
        return index
    }

    private func yPosition(of leaf: PackedLeafNode) -> CGFloat {
        var y = leaf.left?.data.totalLineHeight ?? 0
        var working = leaf
        while let parent = working.parent {
            if working === parent.right {
                if let left = parent.left {
                    y += left.data.totalLineHeight
                }
                y += parent.data.heightSum
            }
            working = parent
        }
        return y
    }

    private func slotUTF16Prefix(leaf: PackedLeafNode, slot: Int) -> Int {
        var total = 0
        for index in 0..<slot {
            total += Int(leaf.data.lines[index].utf16Length)
        }
        return total
    }

    private func slotHeightPrefix(leaf: PackedLeafNode, slot: Int) -> CGFloat {
        var total: CGFloat = 0
        for index in 0..<slot {
            total += CGFloat(leaf.data.lines[index].height)
        }
        return total
    }
}
