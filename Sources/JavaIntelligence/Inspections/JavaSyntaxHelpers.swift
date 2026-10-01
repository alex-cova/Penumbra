import Foundation

extension SyntaxNode {
    /// The named sibling right after this node, if any.
    var nextNamedSibling: SyntaxNode? {
        guard let siblings = parent?.namedChildren, let index = siblings.firstIndex(where: { $0.byteRange == byteRange && $0.type == type }) else {
            return nil
        }
        return index + 1 < siblings.count ? siblings[index + 1] : nil
    }

    /// The named sibling right before this node, if any.
    var previousNamedSibling: SyntaxNode? {
        guard let siblings = parent?.namedChildren, let index = siblings.firstIndex(where: { $0.byteRange == byteRange && $0.type == type }),
              index > 0 else { return nil }
        return siblings[index - 1]
    }

    /// Every named node below this one, depth first, this node excluded.
    func forEachDescendant(_ visit: (SyntaxNode) -> Void) {
        var stack = Array(namedChildren.reversed())
        while let node = stack.popLast() {
            visit(node)
            stack.append(contentsOf: node.namedChildren.reversed())
        }
    }

    /// The operator token of a binary or assignment expression (`==`, `+`, `=`, …).
    var operatorText: String? { child(byFieldName: "operator")?.text }

    /// This node with enclosing parentheses removed.
    var unparenthesized: SyntaxNode {
        var node = self
        while node.type == "parenthesized_expression", let inner = node.namedChild(at: 0) { node = inner }
        return node
    }
}

enum JavaSourceBytes {
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")

    static func lineStart(before byte: Int, in bytes: [UInt8]) -> Int {
        var index = min(byte, bytes.count)
        while index > 0, bytes[index - 1] != newline { index -= 1 }
        return index
    }

    /// The spaces and tabs that start the line containing `byte`.
    static func leadingWhitespace(ofLineContaining byte: Int, in bytes: [UInt8]) -> String {
        var index = lineStart(before: byte, in: bytes)
        var end = index
        while end < bytes.count, bytes[end] == space || bytes[end] == tab { end += 1 }
        index = min(index, end)
        return String(decoding: bytes[index..<end], as: UTF8.self)
    }

    /// Whether a line break lies between two byte offsets.
    static func hasLineBreak(between start: Int, and end: Int, in bytes: [UInt8]) -> Bool {
        guard start < end else { return false }
        return bytes[start..<min(end, bytes.count)].contains(newline)
    }

    /// The bytes to delete to drop `node`: its whole line when nothing else shares the line,
    /// otherwise just the node.
    static func removalRange(of node: SyntaxNode) -> Range<Int> {
        let bytes = node.tree.sourceBytes
        var start = node.startByte
        var end = node.endByte
        while start > 0, bytes[start - 1] == space || bytes[start - 1] == tab { start -= 1 }
        let startsLine = start == 0 || bytes[start - 1] == newline
        while end < bytes.count, bytes[end] == space || bytes[end] == tab { end += 1 }
        let endsLine = end == bytes.count || bytes[end] == newline || bytes[end] == carriageReturn
        guard startsLine, endsLine else { return node.startByte..<node.endByte }
        if end < bytes.count, bytes[end] == carriageReturn { end += 1 }
        if end < bytes.count, bytes[end] == newline { end += 1 }
        return start..<end
    }
}
