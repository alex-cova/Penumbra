import Foundation

/// The "what if" operations of a profiler's call tree, as pure functions over ``JavaProfileTree``.
/// Each returns a new tree and leaves its input alone, so a view can stack them (focus on a
/// subtree, then exclude a call inside it) and undo by dropping the last.
///
/// Node numbers always refer to the tree the operation is called on, which is the tree the user
/// is looking at when the request is made.
extension JavaProfileTree {
    /// Only the subtree below `node`, with `node`'s frame as the single root-level call. The parents'
    /// counts reflect what is left.
    public func focusingOnSubtree(of node: Int) -> JavaProfileTree {
        guard node > 0, node < nodeCount, frame(of: node) >= 0 else { return self }
        var result = JavaProfileTree(nodeLimit: nodeLimit)
        appendSubtree(of: node, prefix: [frame(of: node)], into: &result)
        return result
    }

    /// The method `method` and its callers: every stack is cut where the method's outermost frame
    /// is, and weighs what the method took (so a frame's count is the time spent in the method).
    public func focusingOnCall(of method: Int32, symbols: JavaProfileSymbols) -> JavaProfileTree {
        var result = JavaProfileTree(nodeLimit: nodeLimit)
        for node in outermostNodes(of: method, symbols: symbols) {
            result.add(stack: path(to: node), weight: totalCount(of: node))
        }
        return result
    }

    /// Without `node` and everything below it.
    public func excludingSubtree(of node: Int) -> JavaProfileTree {
        guard node > 0, node < nodeCount else { return self }
        var selfs = allSelfCounts()
        zeroSelfCounts(inSubtreeOf: node, in: &selfs)
        return reweighted(selfCounts: selfs)
    }

    /// Without any call to `method` (its callees go with it).
    public func excludingCalls(of method: Int32, symbols: JavaProfileSymbols) -> JavaProfileTree {
        var selfs = allSelfCounts()
        for node in outermostNodes(of: method, symbols: symbols) { zeroSelfCounts(inSubtreeOf: node, in: &selfs) }
        return reweighted(selfCounts: selfs)
    }

    /// Recursion folded into the first call: a method that is already on the path takes the
    /// later frame's callees, so `a → a → a → b` reads `a → b`.
    public func collapsingRecursion(symbols: JavaProfileSymbols) -> JavaProfileTree {
        var result = JavaProfileTree(nodeLimit: nodeLimit)
        forEachSelfPath { frames, weight in
            var kept: [Int32] = []
            var methods: [Int32] = []
            for frame in frames {
                guard frame >= 0 else {
                    kept.append(frame)
                    methods.append(-1)
                    continue
                }
                let method = symbols.frame(frame).method
                if let earlier = methods.lastIndex(of: method) {
                    kept.removeLast(kept.count - earlier - 1)
                    methods.removeLast(methods.count - earlier - 1)
                } else {
                    kept.append(frame)
                    methods.append(method)
                }
            }
            result.add(stack: kept, weight: weight)
        }
        return result
    }

    /// Without the frames `isHidden` accepts: a hidden frame's callees attach to its caller, which
    /// is how a profiler hides a library or a class it is not interested in.
    public func hidingFrames(
        symbols: JavaProfileSymbols, where isHidden: (JavaProfileSymbols.Method) -> Bool
    ) -> JavaProfileTree {
        var verdicts: [Int32: Bool] = [:]
        var result = JavaProfileTree(nodeLimit: nodeLimit)
        forEachSelfPath { frames, weight in
            var kept: [Int32] = []
            kept.reserveCapacity(frames.count)
            for frame in frames {
                if frame < 0 {
                    kept.append(frame)
                    continue
                }
                let hidden: Bool
                if let known = verdicts[frame] {
                    hidden = known
                } else {
                    hidden = isHidden(symbols.method(ofFrame: frame))
                    verdicts[frame] = hidden
                }
                if !hidden { kept.append(frame) }
            }
            // A sample whose every frame is hidden still counts, at the root.
            result.add(stack: kept, weight: weight)
        }
        return result
    }

    /// Who calls `method`, as a tree: the method at the top, its callers below it, their callers
    /// below those. A sample counts once however deep the method recurses.
    public func backTrace(of method: Int32, symbols: JavaProfileSymbols) -> JavaProfileTree {
        var result = JavaProfileTree(nodeLimit: nodeLimit)
        let nodes = outermostNodes(of: method, symbols: symbols)
        guard let first = nodes.first else { return result }
        // One top frame for the method, whichever line each stack was in it.
        let top = frame(of: first)
        for node in nodes {
            var stack: [Int32] = path(to: node).reversed()
            stack[0] = top
            result.add(stack: stack, weight: totalCount(of: node))
        }
        return result
    }

    /// What `method` calls, merged over every place it is called from: one root-level frame for
    /// the method, then the union of its callees' subtrees.
    public func mergedCallees(of method: Int32, symbols: JavaProfileSymbols) -> JavaProfileTree {
        var result = JavaProfileTree(nodeLimit: nodeLimit)
        let nodes = outermostNodes(of: method, symbols: symbols)
        guard let first = nodes.first else { return result }
        // Merging by method, not frame: the same method at two lines is still one call.
        let top = frame(of: first)
        for node in nodes { appendSubtree(of: node, prefix: [top], into: &result) }
        return result
    }

    // MARK: - Helpers

    /// The nodes of `method` that have no frame of the same method above them.
    private func outermostNodes(of method: Int32, symbols: JavaProfileSymbols) -> [Int] {
        var result: [Int] = []
        var stack: [Int] = [Self.root]
        while let node = stack.popLast() {
            for child in children(of: node) {
                let childFrame = frame(of: child)
                if childFrame >= 0, symbols.frame(childFrame).method == method {
                    result.append(child)
                } else {
                    stack.append(child)
                }
            }
        }
        return result
    }

    private func allSelfCounts() -> [Int] {
        (0..<nodeCount).map { selfCount(of: $0) }
    }

    private func zeroSelfCounts(inSubtreeOf node: Int, in selfs: inout [Int]) {
        var stack = [node]
        while let current = stack.popLast() {
            selfs[current] = 0
            var child = firstChild(of: current)
            while child >= 0 {
                stack.append(Int(child))
                child = nextSibling(of: Int(child))
            }
        }
    }

    /// Calls `body` with each node's frames (root first, `(other)` included) and self weight, for
    /// every node that has samples of its own.
    private func forEachSelfPath(_ body: ([Int32], Int) -> Void) {
        var stack: [(node: Int, frames: [Int32])] = [(Self.root, [])]
        while let (node, frames) = stack.popLast() {
            var frames = frames
            if node != Self.root { frames.append(frame(of: node)) }
            let own = selfCount(of: node)
            if own > 0 { body(frames, own) }
            for child in children(of: node) { stack.append((child, frames)) }
        }
    }

    /// Adds every sample below `node`, with its path relative to `node`, behind `prefix`.
    private func appendSubtree(of node: Int, prefix: [Int32], into result: inout JavaProfileTree) {
        var stack: [(node: Int, frames: [Int32])] = [(node, prefix)]
        while let (current, frames) = stack.popLast() {
            let own = selfCount(of: current)
            if own > 0 { result.add(stack: frames, weight: own) }
            for child in children(of: current) {
                var next = frames
                next.append(frame(of: child))
                stack.append((child, next))
            }
        }
    }
}

/// A class name pattern for hiding frames (`JavaProfileTree.hidingFrames`): `*` stands for any
/// run of characters, and a pattern without one names a class, its nested classes, or a package
/// and everything below it. `org.springframework` hides `org.springframework.web.Dispatcher`,
/// `com.acme.Util` hides `com.acme.Util$Helper`, `*Proxy` hides every class ending in `Proxy`.
public struct JavaClassPattern: Hashable, Sendable {
    public let text: String
    private let parts: [Substring]
    private let isWildcard: Bool

    /// `nil` for an empty pattern, which would match nothing meaningful.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains(where: { $0 != "*" }) else { return nil }
        self.text = trimmed
        self.isWildcard = trimmed.contains("*")
        self.parts = trimmed.split(separator: "*", omittingEmptySubsequences: false)
    }

    /// Patterns from user input: comma, space or newline separated.
    public static func list(from text: String) -> [JavaClassPattern] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == ";" })
            .compactMap { JavaClassPattern(String($0)) }
    }

    public func matches(className: String) -> Bool {
        guard !className.isEmpty else { return false }
        if !isWildcard {
            guard className.hasPrefix(text) else { return false }
            if className.count == text.count { return true }
            let next = className[className.index(className.startIndex, offsetBy: text.count)]
            return next == "." || next == "$"
        }
        // The first part is anchored at the start and the last at the end; the ones between are
        // found in order.
        var rest = Substring(className)
        for (index, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if index == 0 {
                guard rest.hasPrefix(part) else { return false }
                rest = rest.dropFirst(part.count)
            } else if index == parts.count - 1 {
                guard rest.hasSuffix(part) else { return false }
                return true
            } else {
                guard let found = rest.range(of: part) else { return false }
                rest = rest[found.upperBound...]
            }
        }
        // A pattern ending in `*` accepts the remainder; one ending in text was handled above.
        return parts.last?.isEmpty ?? true
    }
}
