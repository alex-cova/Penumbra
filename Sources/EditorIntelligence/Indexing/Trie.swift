import Foundation

/// Prefix tree supporting insertion, removal, and prefix lookup of hashable values keyed by a string.
final class Trie<Value: Hashable> {
    private final class Node {
        var children: [Character: Node] = [:]
        var values: Set<Value> = []
        var isEmpty: Bool { children.isEmpty && values.isEmpty }
    }

    private let root = Node()

    init() {}

    /// Insert a value under the given key.
    func insert(_ key: String, value: Value) {
        var node = root
        for char in key {
            if node.children[char] == nil {
                node.children[char] = Node()
            }
            node = node.children[char]!
        }
        node.values.insert(value)
    }

    /// Remove a specific value from the given key. Returns true if the value was found.
    @discardableResult
    func remove(_ key: String, value: Value) -> Bool {
        var node = root
        var path: [(Character, Node)] = []
        for char in key {
            guard let child = node.children[char] else { return false }
            path.append((char, node))
            node = child
        }
        guard node.values.remove(value) != nil else { return false }
        cleanup(path: path)
        return true
    }

    /// Releasing a deep chain of nodes would recurse once per character, so detach the tree level by
    /// level instead. Each node is released with no children left, which keeps the cascade one deep.
    deinit {
        var pending = [root]
        while let current = pending.popLast() {
            pending.append(contentsOf: current.children.values)
            current.children.removeAll()
        }
    }

    /// Find values whose key starts with the given prefix, shortest keys first.
    ///
    /// `include` is applied before `limit`, so a filtered-out value never uses up the cap. With no
    /// `limit` every matching value is returned.
    func search(prefix: String, limit: Int? = nil, where include: (Value) -> Bool = { _ in true }) -> [Value] {
        var node = root
        for char in prefix {
            guard let child = node.children[char] else { return [] }
            node = child
        }
        return collectValues(from: node, limit: limit, where: include)
    }

    /// Find all values stored under exactly this key. Cost is the key length, not the size of the subtree.
    func search(exact key: String) -> [Value] {
        var node = root
        for char in key {
            guard let child = node.children[char] else { return [] }
            node = child
        }
        return Array(node.values)
    }

    private func cleanup(path: [(Character, Node)]) {
        for (char, parent) in path.reversed() {
            if let child = parent.children[char], child.isEmpty {
                parent.children.removeValue(forKey: char)
            } else {
                break
            }
        }
    }

    /// Iterative on purpose: keys can be arbitrarily long (generated or minified identifiers), and a
    /// recursive walk costs one stack frame per character, which overflows the small stacks of
    /// cooperative-pool threads.
    ///
    /// Breadth-first, so shorter keys come out before longer ones and a `limit` keeps the best
    /// candidates for a length-tiebreaking ranker.
    private func collectValues(from node: Node, limit: Int?, where include: (Value) -> Bool) -> [Value] {
        var result: [Value] = []
        if let limit, limit <= 0 { return result }
        var level = [node]
        var next: [Node] = []
        while !level.isEmpty {
            for current in level {
                for value in current.values where include(value) {
                    result.append(value)
                    if let limit, result.count >= limit { return result }
                }
                next.append(contentsOf: current.children.values)
            }
            level = next
            next.removeAll(keepingCapacity: true)
        }
        return result
    }
}
