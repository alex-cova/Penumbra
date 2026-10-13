import Foundation

/// A prefix tree of sampled stacks: one node per distinct call path, with how many samples ended
/// there (`selfCount`) and passed through (`totalCount`). Memory follows the number of distinct
/// stacks, not the number of samples, and a node cap folds the rest into one `(other)` node.
public struct JavaProfileTree: Sendable {
    /// The index of the root node, which stands for "all samples".
    public static let root = 0

    /// A path's frame id, `-1` for the root and `-2` for the `(other)` node.
    public static let otherFrame: Int32 = -2
    public static let rootFrame: Int32 = -1

    /// Nodes past this are not created; the sample goes to `(other)` instead.
    public static let defaultNodeLimit = 200_000

    public let nodeLimit: Int

    private var parents: [Int32] = [-1]
    private var frames: [Int32] = [JavaProfileTree.rootFrame]
    private var selfCounts: [Int] = [0]
    private var totalCounts: [Int] = [0]
    private var firstChildren: [Int32] = [-1]
    private var nextSiblings: [Int32] = [-1]
    private var childIndex: [ChildKey: Int32] = [:]
    private var otherNode: Int32 = -1

    /// How many samples were folded into `(other)`.
    public private(set) var foldedSamples = 0

    private struct ChildKey: Hashable {
        var parent: Int32
        var frame: Int32
    }

    public init(nodeLimit: Int = JavaProfileTree.defaultNodeLimit) {
        self.nodeLimit = max(2, nodeLimit)
    }

    public var nodeCount: Int { parents.count }
    public var totalSamples: Int { totalCounts[0] }
    /// Whether any sample was folded into `(other)`; the UI says so.
    public var isTruncated: Bool { foldedSamples > 0 }

    public func frame(of node: Int) -> Int32 { frames[node] }
    public func parent(of node: Int) -> Int? { parents[node] < 0 ? nil : Int(parents[node]) }
    public func selfCount(of node: Int) -> Int { selfCounts[node] }
    public func totalCount(of node: Int) -> Int { totalCounts[node] }
    public func isOther(_ node: Int) -> Bool { frames[node] == Self.otherFrame }

    /// Children of `node`, hottest first.
    public func children(of node: Int) -> [Int] {
        var result: [Int] = []
        var child = firstChildren[node]
        while child >= 0 {
            result.append(Int(child))
            child = nextSiblings[Int(child)]
        }
        return result.sorted { totalCounts[$0] > totalCounts[$1] }
    }

    public func hasChildren(_ node: Int) -> Bool { firstChildren[node] >= 0 }

    // MARK: - Adding samples

    /// Adds one sample: `stack` is root first (callers before callees), `weight` its size (1 for a
    /// CPU sample, bytes for an allocation).
    public mutating func add(stack: [Int32], weight: Int = 1) {
        guard weight > 0 else { return }
        // Walk what exists, and count the nodes the rest of the stack would need.
        var node = Self.root
        var matched = 0
        while matched < stack.count, let child = childIndex[ChildKey(parent: Int32(node), frame: stack[matched])] {
            node = Int(child)
            matched += 1
        }
        let needed = stack.count - matched
        if needed > 0, nodeCount + needed > nodeLimit {
            fold(weight: weight)
            return
        }
        totalCounts[0] += weight
        node = Self.root
        for frame in stack {
            node = child(of: node, frame: frame)
            totalCounts[node] += weight
        }
        selfCounts[node] += weight
    }

    private mutating func fold(weight: Int) {
        foldedSamples += 1
        totalCounts[0] += weight
        if otherNode < 0 {
            // The reserved node: the limit leaves room for it by never counting it.
            otherNode = Int32(newNode(parent: Self.root, frame: Self.otherFrame))
        }
        totalCounts[Int(otherNode)] += weight
        selfCounts[Int(otherNode)] += weight
    }

    private mutating func child(of parent: Int, frame: Int32) -> Int {
        let key = ChildKey(parent: Int32(parent), frame: frame)
        if let existing = childIndex[key] { return Int(existing) }
        return newNode(parent: parent, frame: frame)
    }

    private mutating func newNode(parent: Int, frame: Int32) -> Int {
        let index = parents.count
        parents.append(Int32(parent))
        frames.append(frame)
        selfCounts.append(0)
        totalCounts.append(0)
        firstChildren.append(-1)
        nextSiblings.append(firstChildren[parent])
        firstChildren[parent] = Int32(index)
        childIndex[ChildKey(parent: Int32(parent), frame: frame)] = Int32(index)
        return index
    }

    // MARK: - Derived views

    public struct HotMethod: Equatable, Sendable {
        public var method: Int32
        public var selfCount: Int
        /// Samples with the method anywhere on the stack, each counted once (recursion included).
        public var totalCount: Int

        public init(method: Int32, selfCount: Int, totalCount: Int) {
            self.method = method
            self.selfCount = selfCount
            self.totalCount = totalCount
        }
    }

    /// Methods by self time, merged over lines and call paths. `limit` keeps the top of the list.
    public func hotMethods(symbols: JavaProfileSymbols, limit: Int? = nil) -> [HotMethod] {
        var selfByMethod: [Int32: Int] = [:]
        var totalByMethod: [Int32: Int] = [:]
        // `active[m]` is how many frames of method m are on the path being walked, so a method's
        // total is counted at its outermost frame only.
        var active: [Int32: Int] = [:]
        var stack: [(node: Int, expanded: Bool)] = [(Self.root, false)]
        while let (node, expanded) = stack.popLast() {
            let frame = frames[node]
            let method: Int32? = frame >= 0 ? symbols.frame(frame).method : nil
            if expanded {
                if let method { active[method, default: 0] -= 1 }
                continue
            }
            if let method {
                selfByMethod[method, default: 0] += selfCounts[node]
                if active[method, default: 0] == 0 { totalByMethod[method, default: 0] += totalCounts[node] }
                active[method, default: 0] += 1
                stack.append((node, true))
            }
            var child = firstChildren[node]
            while child >= 0 {
                stack.append((Int(child), false))
                child = nextSiblings[Int(child)]
            }
        }
        var result = totalByMethod.map { HotMethod(method: $0.key, selfCount: selfByMethod[$0.key] ?? 0, totalCount: $0.value) }
        result.sort { lhs, rhs in
            if lhs.selfCount != rhs.selfCount { return lhs.selfCount > rhs.selfCount }
            if lhs.totalCount != rhs.totalCount { return lhs.totalCount > rhs.totalCount }
            return lhs.method < rhs.method
        }
        if let limit { return Array(result.prefix(limit)) }
        return result
    }

    public struct Neighbour: Equatable, Sendable {
        public var method: Int32
        public var count: Int
    }

    /// Who calls `method`, by the samples that go through each caller, hottest first. A method
    /// calling itself is not its own caller.
    public func callers(of method: Int32, symbols: JavaProfileSymbols) -> [Neighbour] {
        var counts: [Int32: Int] = [:]
        for node in 1..<nodeCount where frames[node] >= 0 && symbols.frame(frames[node]).method == method {
            let parent = Int(parents[node])
            guard frames[parent] >= 0 else { continue }
            let caller = symbols.frame(frames[parent]).method
            if caller != method { counts[caller, default: 0] += totalCounts[node] }
        }
        return counts.map { Neighbour(method: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    /// What `method` calls, by samples, hottest first.
    public func callees(of method: Int32, symbols: JavaProfileSymbols) -> [Neighbour] {
        var counts: [Int32: Int] = [:]
        for node in 1..<nodeCount where frames[node] >= 0 && symbols.frame(frames[node]).method == method {
            var child = firstChildren[node]
            while child >= 0 {
                let childFrame = frames[Int(child)]
                if childFrame >= 0 {
                    let callee = symbols.frame(childFrame).method
                    if callee != method { counts[callee, default: 0] += totalCounts[Int(child)] }
                }
                child = nextSiblings[Int(child)]
            }
        }
        return counts.map { Neighbour(method: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    /// The frames from the root to `node` (root excluded), outermost first.
    public func path(to node: Int) -> [Int32] {
        var result: [Int32] = []
        var current = node
        while current > 0 {
            result.append(frames[current])
            current = Int(parents[current])
        }
        return result.reversed()
    }

    /// Brendan Gregg's folded format, `a;b;c 12` per distinct stack with self samples, for other
    /// flame graph tools. Frames are `Class.method`, without lines.
    public func foldedStacks(symbols: JavaProfileSymbols) -> [String] {
        var lines: [String] = []
        var stack: [(node: Int, names: [String])] = [(Self.root, [])]
        while let (node, names) = stack.popLast() {
            var names = names
            if node != Self.root {
                names.append(frames[node] == Self.otherFrame
                    ? "(other)"
                    : symbols.qualifiedName(ofMethod: symbols.frame(frames[node]).method))
            }
            if selfCounts[node] > 0, !names.isEmpty { lines.append(names.joined(separator: ";") + " \(selfCounts[node])") }
            var child = firstChildren[node]
            while child >= 0 {
                stack.append((Int(child), names))
                child = nextSiblings[Int(child)]
            }
        }
        return lines.sorted()
    }
}

/// One garbage collection, as the GC tab lists it.
public struct JavaGCPause: Equatable, Sendable {
    public var gcID: Int?
    public var name: String
    public var cause: String
    public var nanoseconds: Int

    public init(gcID: Int?, name: String, cause: String, nanoseconds: Int) {
        self.gcID = gcID
        self.name = name
        self.cause = cause
        self.nanoseconds = nanoseconds
    }
}

/// A recording, read: the stack trees per kind (and per thread for CPU), the symbols they use and
/// what was left out.
public struct JavaProfile: Sendable {
    public let symbols: JavaProfileSymbols
    public var cpu = JavaProfileTree()
    public var allocation = JavaProfileTree()
    public var contention = JavaProfileTree()
    /// CPU trees per thread name, for the thread filter; at most ``maximumThreads``.
    public var cpuByThread: [String: JavaProfileTree] = [:]
    public var gcPauses: [JavaGCPause] = []
    /// Samples whose stack was cut off (`...`), which the UI reports.
    public var truncatedSamples = 0
    public var threadsOverLimit = 0

    public static let maximumThreads = 64

    public init(symbols: JavaProfileSymbols = JavaProfileSymbols()) {
        self.symbols = symbols
    }

    public var cpuSamples: Int { cpu.totalSamples }
    public var isEmpty: Bool { cpu.totalSamples == 0 && allocation.totalSamples == 0 && contention.totalSamples == 0 && gcPauses.isEmpty }

    /// The CPU tree of one thread, or the whole profile's for `nil`.
    public func cpuTree(thread: String?) -> JavaProfileTree {
        guard let thread else { return cpu }
        return cpuByThread[thread] ?? JavaProfileTree()
    }

    /// Adds `event` to the tree of its kind.
    public mutating func ingest(_ event: JFRTextEvent) {
        let rootFirst = Array(event.frames.reversed())
        switch event.type {
        case JavaFlightRecorder.EventType.executionSample:
            if event.isTruncated { truncatedSamples += 1 }
            cpu.add(stack: rootFirst)
            if let thread = event.thread {
                if cpuByThread[thread] != nil || cpuByThread.count < Self.maximumThreads {
                    cpuByThread[thread, default: JavaProfileTree()].add(stack: rootFirst)
                } else {
                    threadsOverLimit += 1
                }
            }
        case JavaFlightRecorder.EventType.allocationSample:
            // The sample's weight is the bytes it stands for; the class is the leaf.
            if let weight = event.bytes("weight"), weight > 0 {
                var stack = rootFirst
                if let objectClass = event.attributes["objectClass"] {
                    let name = objectClass.split(separator: " ").first.map(String.init) ?? objectClass
                    let method = symbols.internMethod(className: "", name: "new " + name, parameters: "")
                    stack.append(symbols.internFrame(method: method, line: 0))
                }
                allocation.add(stack: stack, weight: weight)
            }
        case JavaFlightRecorder.EventType.monitorEnter, JavaFlightRecorder.EventType.threadPark:
            if let duration = event.nanoseconds("duration"), duration > 0 {
                var stack = rootFirst
                let owner = event.attributes["monitorClass"] ?? event.attributes["parkedClass"]
                if let owner {
                    let name = owner.split(separator: " ").first.map(String.init) ?? owner
                    let prefix = event.type == JavaFlightRecorder.EventType.monitorEnter ? "waiting for " : "parked on "
                    let method = symbols.internMethod(className: "", name: prefix + name, parameters: "")
                    stack.append(symbols.internFrame(method: method, line: 0))
                }
                contention.add(stack: stack, weight: max(1, duration / 1_000))
            }
        case JavaFlightRecorder.EventType.garbageCollection:
            gcPauses.append(JavaGCPause(
                gcID: event.attributes["gcId"].flatMap(Int.init),
                name: event.attributes["name"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? "GC",
                cause: event.attributes["cause"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? "",
                nanoseconds: event.nanoseconds("sumOfPauses") ?? event.nanoseconds("duration") ?? 0
            ))
        default:
            break
        }
    }
}
