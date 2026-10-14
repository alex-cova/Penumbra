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

    /// Children of `node`, hottest first. A child a filter left with no samples is not listed.
    public func children(of node: Int) -> [Int] {
        var result: [Int] = []
        var child = firstChildren[node]
        while child >= 0 {
            if totalCounts[Int(child)] > 0 { result.append(Int(child)) }
            child = nextSiblings[Int(child)]
        }
        return result.sorted { totalCounts[$0] > totalCounts[$1] }
    }

    public func hasChildren(_ node: Int) -> Bool {
        var child = firstChildren[node]
        while child >= 0 {
            if totalCounts[Int(child)] > 0 { return true }
            child = nextSiblings[Int(child)]
        }
        return false
    }

    func firstChild(of node: Int) -> Int32 { firstChildren[node] }
    func nextSibling(of node: Int) -> Int32 { nextSiblings[node] }

    /// The same tree with other self counts per node (`selfCounts[i]` for node `i`; a shorter array
    /// leaves the rest at 0), totals recomputed in one pass. Nodes are created after their parents,
    /// so a reverse walk over the indexes folds every child into its parent. This is what a thread or
    /// time-range filter costs: the samples that match, plus the nodes, and no tree is rebuilt.
    public func reweighted(selfCounts newSelf: [Int]) -> JavaProfileTree {
        var copy = self
        var selfs = newSelf
        if selfs.count < nodeCount { selfs.append(contentsOf: repeatElement(0, count: nodeCount - selfs.count)) }
        if selfs.count > nodeCount { selfs.removeLast(selfs.count - nodeCount) }
        var totals = selfs
        var index = nodeCount - 1
        while index >= 1 {
            totals[Int(parents[index])] += totals[index]
            index -= 1
        }
        copy.selfCounts = selfs
        copy.totalCounts = totals
        if otherNode >= 0, totals[Int(otherNode)] == 0 { copy.foldedSamples = 0 }
        return copy
    }

    // MARK: - Adding samples

    /// Adds one sample: `stack` is root first (callers before callees), `weight` its size (1 for a
    /// CPU sample, bytes for an allocation). Returns the node the sample ended in (the `(other)` node
    /// for a folded one), which is how a sample refers to its stack afterwards; `nil` for a weight
    /// that is not positive.
    @discardableResult
    public mutating func add(stack: [Int32], weight: Int = 1) -> Int? {
        guard weight > 0 else { return nil }
        // Walk what exists, and count the nodes the rest of the stack would need.
        var node = Self.root
        var matched = 0
        while matched < stack.count, let child = childIndex[ChildKey(parent: Int32(node), frame: stack[matched])] {
            node = Int(child)
            matched += 1
        }
        let needed = stack.count - matched
        if needed > 0, nodeCount + needed > nodeLimit {
            return fold(weight: weight)
        }
        totalCounts[0] += weight
        node = Self.root
        for frame in stack {
            node = child(of: node, frame: frame)
            totalCounts[node] += weight
        }
        selfCounts[node] += weight
        return node
    }

    private mutating func fold(weight: Int) -> Int {
        foldedSamples += 1
        totalCounts[0] += weight
        if otherNode < 0 {
            // The reserved node: the limit leaves room for it by never counting it.
            otherNode = Int32(newNode(parent: Self.root, frame: Self.otherFrame))
        }
        totalCounts[Int(otherNode)] += weight
        selfCounts[Int(otherNode)] += weight
        return Int(otherNode)
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
            if !expanded, totalCounts[node] == 0 { continue }
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
        for node in 1..<nodeCount where totalCounts[node] > 0 && frames[node] >= 0 && symbols.frame(frames[node]).method == method {
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
        for node in 1..<nodeCount where totalCounts[node] > 0 && frames[node] >= 0 && symbols.frame(frames[node]).method == method {
            var child = firstChildren[node]
            while child >= 0 {
                let childFrame = frames[Int(child)]
                if childFrame >= 0, totalCounts[Int(child)] > 0 {
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
    /// Start, in milliseconds from ``JavaProfile/timeSpan``'s origin; `nil` when the event had no time.
    public var startMilliseconds: Int32?

    public init(gcID: Int?, name: String, cause: String, nanoseconds: Int, startMilliseconds: Int32? = nil) {
        self.gcID = gcID
        self.name = name
        self.cause = cause
        self.nanoseconds = nanoseconds
        self.startMilliseconds = startMilliseconds
    }
}

/// What a sample stands for: running Java code, an allocation (bytes), or time spent waiting
/// (microseconds: a monitor, a park, a sleep, a socket or file read).
public enum JavaSampleKind: Int, CaseIterable, Sendable {
    case cpu
    case allocation
    case contention
}

/// The samples of one kind in the order they were read: a time, a thread, the node of the profile
/// tree the sample's stack ended in, and its weight. A stack is its leaf node, so a thread filter or
/// a time range is a pass over these arrays and ``JavaProfileTree/reweighted(selfCounts:)``.
public struct JavaSampleTable: Sendable {
    /// Rows past this are counted in ``dropped`` and left out of range and thread queries; the
    /// profile tree still has them.
    public static let capacity = 2_000_000

    /// Milliseconds from the profile's origin; may be negative (events are not read in time order).
    public private(set) var times: [Int32] = []
    /// Index into ``JavaProfile/threadNames``, or ``JavaProfile/noThread``.
    public private(set) var threads: [UInt16] = []
    public private(set) var nodes: [Int32] = []
    public private(set) var weights: [Int32] = []
    public private(set) var dropped = 0

    public init() {}

    public var count: Int { times.count }

    mutating func append(time: Int32, thread: UInt16, node: Int, weight: Int) {
        guard times.count < Self.capacity else {
            dropped += 1
            return
        }
        times.append(time)
        threads.append(thread)
        nodes.append(Int32(truncatingIfNeeded: node))
        weights.append(Int32(clamping: weight))
    }
}

/// `jdk.CPULoad`: shares of the machine's CPU, 0...1.
public struct JavaLoadPoint: Equatable, Sendable {
    public var time: Int32
    public var jvmUser: Float
    public var jvmSystem: Float
    public var machineTotal: Float

    public init(time: Int32, jvmUser: Float, jvmSystem: Float, machineTotal: Float) {
        self.time = time
        self.jvmUser = jvmUser
        self.jvmSystem = jvmSystem
        self.machineTotal = machineTotal
    }

    public var jvmTotal: Float { jvmUser + jvmSystem }
}

/// `jdk.GCHeapSummary`: heap in use at a collection, before or after it.
public struct JavaHeapPoint: Equatable, Sendable {
    public var time: Int32
    public var usedBytes: Int
    public var afterCollection: Bool

    public init(time: Int32, usedBytes: Int, afterCollection: Bool) {
        self.time = time
        self.usedBytes = usedBytes
        self.afterCollection = afterCollection
    }
}

/// A recording, read: the stack trees per kind, a sample table per kind (so threads and time ranges
/// are queries), the symbols they use and what was left out.
public struct JavaProfile: Sendable {
    public let symbols: JavaProfileSymbols
    public var cpu = JavaProfileTree()
    public var allocation = JavaProfileTree()
    /// Every wait: monitors, parks, sleeps, `wait()`, socket and file reads and writes, weighted in µs.
    public var contention = JavaProfileTree()
    public var gcPauses: [JavaGCPause] = []
    public private(set) var cpuSamplesTable = JavaSampleTable()
    public private(set) var allocationSamplesTable = JavaSampleTable()
    public private(set) var contentionSamplesTable = JavaSampleTable()
    public private(set) var cpuLoad: [JavaLoadPoint] = []
    public private(set) var heap: [JavaHeapPoint] = []
    /// Thread names, in the order they were first seen; a sample's thread is an index into this.
    public private(set) var threadNames: [String] = []
    /// Samples whose stack was cut off (`...`), which the UI reports.
    public var truncatedSamples = 0
    /// Events whose thread did not get an index because ``maximumThreads`` names were known.
    public var threadsOverLimit = 0

    /// A sample with no thread.
    public static let noThread: UInt16 = .max
    public static let maximumThreads = 10_000

    private var threadIndex: [String: UInt16] = [:]
    private var originMillis: Int64?
    private var firstTime: Int32 = .max
    private var lastTime: Int32 = .min
    private let queries = QueryCache()

    public init(symbols: JavaProfileSymbols = JavaProfileSymbols()) {
        self.symbols = symbols
    }

    public var cpuSamples: Int { cpu.totalSamples }
    public var isEmpty: Bool { cpu.totalSamples == 0 && allocation.totalSamples == 0 && contention.totalSamples == 0 && gcPauses.isEmpty }

    /// The first and last event time in milliseconds from the origin (the first event read), or
    /// `nil` when no event had a time. Its length is what the timeline's axis covers.
    public var timeSpan: ClosedRange<Int32>? { firstTime <= lastTime ? firstTime...lastTime : nil }

    public func tree(of kind: JavaSampleKind) -> JavaProfileTree {
        switch kind {
        case .cpu: return cpu
        case .allocation: return allocation
        case .contention: return contention
        }
    }

    public func samples(of kind: JavaSampleKind) -> JavaSampleTable {
        switch kind {
        case .cpu: return cpuSamplesTable
        case .allocation: return allocationSamplesTable
        case .contention: return contentionSamplesTable
        }
    }

    /// The CPU tree of one thread, or the whole profile's for `nil`.
    public func cpuTree(thread: String?) -> JavaProfileTree {
        tree(of: .cpu, thread: thread, range: nil)
    }

    /// The tree of `kind` restricted to one thread and/or a time range (milliseconds from the
    /// origin, both ends included). With neither it is the full tree; an unknown thread is empty.
    /// Results are cached (the last few queries), so a view may ask on every update.
    public func tree(of kind: JavaSampleKind, thread: String?, range: ClosedRange<Int32>?) -> JavaProfileTree {
        let base = tree(of: kind)
        if thread == nil, range == nil { return base }
        let key = QueryKey(kind: kind, thread: thread, lower: range?.lowerBound, upper: range?.upperBound)
        if let cached = queries.value(for: key) { return cached }
        var wantedThread: UInt16?
        if let thread {
            guard let index = threadIndex[thread] else {
                let empty = JavaProfileTree()
                queries.store(empty, for: key)
                return empty
            }
            wantedThread = index
        }
        let table = samples(of: kind)
        var selfs = [Int](repeating: 0, count: base.nodeCount)
        for row in 0..<table.count {
            if let range, !range.contains(table.times[row]) { continue }
            if let wantedThread, table.threads[row] != wantedThread { continue }
            let node = Int(table.nodes[row])
            if node < selfs.count { selfs[node] += Int(table.weights[row]) }
        }
        let result = base.reweighted(selfCounts: selfs)
        queries.store(result, for: key)
        return result
    }

    /// Thread names with their sample counts for `kind`, most samples first.
    public func threads(of kind: JavaSampleKind) -> [(name: String, samples: Int)] {
        let table = samples(of: kind)
        var counts = [Int](repeating: 0, count: threadNames.count)
        for row in 0..<table.count {
            let thread = Int(table.threads[row])
            if thread < counts.count { counts[thread] += 1 }
        }
        return threadNames.indices
            .filter { counts[$0] > 0 }
            .map { (threadNames[$0], counts[$0]) }
            .sorted { $0.samples != $1.samples ? $0.samples > $1.samples : $0.name < $1.name }
    }

    /// The CPU sampling period read off the recording: the median gap between a busy thread's
    /// consecutive samples. `nil` below eight samples of one thread.
    public func estimatedCPUSamplePeriodMilliseconds() -> Double? {
        let table = cpuSamplesTable
        guard table.count >= 8 else { return nil }
        var perThread: [UInt16: Int] = [:]
        for thread in table.threads { perThread[thread, default: 0] += 1 }
        guard let busiest = perThread.max(by: { $0.value < $1.value }), busiest.value >= 8 else { return nil }
        var times: [Int32] = []
        times.reserveCapacity(busiest.value)
        for row in 0..<table.count where table.threads[row] == busiest.key { times.append(table.times[row]) }
        times.sort()
        var gaps: [Int32] = []
        for index in 1..<times.count where times[index] > times[index - 1] { gaps.append(times[index] - times[index - 1]) }
        guard !gaps.isEmpty else { return nil }
        gaps.sort()
        return Double(gaps[gaps.count / 2])
    }

    // MARK: - Ingest

    /// Adds `event` to the tree and the sample table of its kind.
    public mutating func ingest(_ event: JFRTextEvent) {
        let rootFirst = Array(event.frames.reversed())
        let time = offset(of: event)
        let thread = threadReference(for: event)
        switch event.type {
        case JavaFlightRecorder.EventType.executionSample:
            if event.isTruncated { truncatedSamples += 1 }
            if let node = cpu.add(stack: rootFirst) {
                cpuSamplesTable.append(time: time ?? 0, thread: thread, node: node, weight: 1)
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
                if let node = allocation.add(stack: stack, weight: weight) {
                    allocationSamplesTable.append(time: time ?? 0, thread: thread, node: node, weight: weight)
                }
            }
        case JavaFlightRecorder.EventType.monitorEnter, JavaFlightRecorder.EventType.threadPark,
             JavaFlightRecorder.EventType.threadSleep, JavaFlightRecorder.EventType.monitorWait,
             JavaFlightRecorder.EventType.socketRead, JavaFlightRecorder.EventType.socketWrite,
             JavaFlightRecorder.EventType.fileRead, JavaFlightRecorder.EventType.fileWrite:
            if let duration = event.nanoseconds("duration"), duration > 0 {
                var stack = rootFirst
                if let label = Self.waitLabel(for: event) {
                    let method = symbols.internMethod(className: "", name: label, parameters: "")
                    stack.append(symbols.internFrame(method: method, line: 0))
                }
                let weight = max(1, duration / 1_000)
                if let node = contention.add(stack: stack, weight: weight) {
                    contentionSamplesTable.append(time: time ?? 0, thread: thread, node: node, weight: weight)
                }
            }
        case JavaFlightRecorder.EventType.garbageCollection:
            gcPauses.append(JavaGCPause(
                gcID: event.attributes["gcId"].flatMap(Int.init),
                name: event.attributes["name"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? "GC",
                cause: event.attributes["cause"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? "",
                nanoseconds: event.nanoseconds("sumOfPauses") ?? event.nanoseconds("duration") ?? 0,
                startMilliseconds: time
            ))
        case JavaFlightRecorder.EventType.cpuLoad:
            if let time, let user = event.fraction("jvmUser") {
                cpuLoad.append(JavaLoadPoint(
                    time: time, jvmUser: Float(user), jvmSystem: Float(event.fraction("jvmSystem") ?? 0),
                    machineTotal: Float(event.fraction("machineTotal") ?? 0)
                ))
            }
        case JavaFlightRecorder.EventType.gcHeapSummary:
            if let time, let used = event.bytes("heapUsed") {
                let when = event.attributes["when"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
                heap.append(JavaHeapPoint(time: time, usedBytes: used, afterCollection: when.hasPrefix("After")))
            }
        default:
            break
        }
        queries.removeAll()
    }

    /// The synthetic leaf frame that says what a wait was for.
    static func waitLabel(for event: JFRTextEvent) -> String? {
        func trimmed(_ key: String) -> String? {
            guard let value = event.attributes[key] else { return nil }
            return value.split(separator: " ").first.map(String.init) ?? value
        }
        switch event.type {
        case JavaFlightRecorder.EventType.monitorEnter:
            return trimmed("monitorClass").map { "waiting for " + $0 }
        case JavaFlightRecorder.EventType.threadPark:
            return trimmed("parkedClass").map { "parked on " + $0 } ?? "parked"
        case JavaFlightRecorder.EventType.monitorWait:
            return trimmed("monitorClass").map { "Object.wait on " + $0 } ?? "Object.wait"
        case JavaFlightRecorder.EventType.threadSleep:
            return "sleeping"
        case JavaFlightRecorder.EventType.socketRead, JavaFlightRecorder.EventType.socketWrite:
            let verb = event.type == JavaFlightRecorder.EventType.socketRead ? "socket read" : "socket write"
            let host = trimmed("host").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            // The host and not the port: every connection has its own, and they would not group.
            if let host, !host.isEmpty { return verb + " " + host }
            return verb
        case JavaFlightRecorder.EventType.fileRead, JavaFlightRecorder.EventType.fileWrite:
            let verb = event.type == JavaFlightRecorder.EventType.fileRead ? "file read" : "file write"
            let path = event.attributes["path"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let path, !path.isEmpty { return verb + " " + (path.split(separator: "/").last.map(String.init) ?? path) }
            return verb
        default:
            return nil
        }
    }

    private mutating func offset(of event: JFRTextEvent) -> Int32? {
        guard let millis = event.timeMillis else { return nil }
        let origin = originMillis ?? millis
        originMillis = origin
        let value = Int32(clamping: millis - origin)
        firstTime = min(firstTime, value)
        lastTime = max(lastTime, value)
        return value
    }

    private mutating func threadReference(for event: JFRTextEvent) -> UInt16 {
        guard let name = event.thread else { return Self.noThread }
        if let existing = threadIndex[name] { return existing }
        guard threadNames.count < Self.maximumThreads else {
            threadsOverLimit += 1
            return Self.noThread
        }
        let index = UInt16(threadNames.count)
        threadNames.append(name)
        threadIndex[name] = index
        return index
    }

    // MARK: - Query cache

    private struct QueryKey: Hashable {
        var kind: JavaSampleKind
        var thread: String?
        var lower: Int32?
        var upper: Int32?
    }

    /// The last few filtered trees. A reference type so that the copies of a finished profile (a
    /// session holds one) share it; `ingest` clears it while a recording is still being read.
    private final class QueryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: QueryKey, tree: JavaProfileTree)] = []

        func value(for key: QueryKey) -> JavaProfileTree? {
            lock.withLock { entries.first { $0.key == key }?.tree }
        }

        func store(_ tree: JavaProfileTree, for key: QueryKey) {
            lock.withLock {
                entries.removeAll { $0.key == key }
                entries.append((key, tree))
                if entries.count > 6 { entries.removeFirst() }
            }
        }

        func removeAll() {
            lock.withLock { if !entries.isEmpty { entries.removeAll() } }
        }
    }
}
