import Darwin
import Foundation

/// A reference between two objects: the other end, and whether it is a `Reference.referent`.
public struct HeapEdge: Sendable, Hashable {
    public let object: Int32
    public let isWeak: Bool

    public init(object: Int32, isWeak: Bool) {
        self.object = object
        self.isWeak = isWeak
    }
}

/// A GC root as the dump names it.
public struct HeapRoot: Sendable, Hashable {
    public let kind: HprofRootKind
    public let id: UInt64
    /// Nil when the id names no object in the dump.
    public let object: Int32?
    /// Thread serial (Java frame, JNI local, thread object, native stack, thread block).
    public let threadSerial: UInt32
    /// Frame number (Java frame, JNI local) or stack trace serial (thread object).
    public let detail: UInt32
}

/// A value read out of the dump: a field, a static, or an array element.
public enum HeapValue: Sendable, Hashable, CustomStringConvertible {
    case null
    case object(Int32)
    /// A reference to an id the dump does not contain.
    case unresolved(UInt64)
    case boolean(Bool)
    case char(UInt16)
    case byte(Int8)
    case short(Int16)
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)

    public var description: String {
        switch self {
        case .null: return "null"
        case .object(let n): return "#\(n)"
        case .unresolved(let id): return String(format: "0x%llx (not in the dump)", id)
        case .boolean(let value): return value ? "true" : "false"
        case .char(let value):
            if let scalar = Unicode.Scalar(value), !CharacterSet.controlCharacters.contains(scalar) {
                return "'\(Character(scalar))'"
            }
            return String(format: "'\\u%04x'", value)
        case .byte(let value): return String(value)
        case .short(let value): return String(value)
        case .int(let value): return String(value)
        case .long(let value): return String(value)
        case .float(let value): return String(value)
        case .double(let value): return String(value)
        }
    }

    public var objectNumber: Int32? {
        if case .object(let n) = self { return n }
        return nil
    }

    /// From raw big-endian bits as HPROF stores them.
    static func decode(_ bits: UInt64, type: HprofBasicType, lookup: (UInt64) -> Int32?) -> HeapValue {
        switch type {
        case .object:
            guard bits != 0 else { return .null }
            return lookup(bits).map(HeapValue.object) ?? .unresolved(bits)
        case .boolean: return .boolean(bits != 0)
        case .char: return .char(UInt16(truncatingIfNeeded: bits))
        case .byte: return .byte(Int8(bitPattern: UInt8(truncatingIfNeeded: bits)))
        case .short: return .short(Int16(bitPattern: UInt16(truncatingIfNeeded: bits)))
        case .int: return .int(Int32(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case .long: return .long(Int64(bitPattern: bits))
        case .float: return .float(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case .double: return .double(Double(bitPattern: bits))
        }
    }
}

/// A named value of an object: an instance field, a static (`static NAME`), an array element
/// (`[3]`), or a class's `<superclass>` and `<class loader>`.
public struct HeapField: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let type: HprofBasicType
    public let value: HeapValue
}

/// The object index of a heap dump, read-only and `Sendable`: built by `HeapIndexBuilder`, opened
/// from disk by `HeapIndexStore`. Every query is bounded by what it returns (a page of
/// instances, one object's fields, a range of referrers), never by the number of objects.
public final class HeapIndex: @unchecked Sendable {
    public let directory: URL
    public let dumpURL: URL
    /// Objects in the dump; numbers run 1...objectCount (0 is the super-root).
    public let objectCount: Int
    public let referenceCount: Int
    public let danglingReferences: Int
    public let idSize: Int
    public let layout: HeapObjectLayout
    public let buildSeconds: Double
    public let classes: [HeapClass]
    public let roots: [HeapRoot]
    /// The group of all `java.lang.Class` mirrors in `classes`.
    public let mirrorGroup: Int32

    let ids: HeapMappedArray<UInt64>
    let offsets: HeapMappedArray<Int64>
    let classIndexes: HeapMappedArray<Int32>
    let kinds: HeapMappedArray<UInt8>
    let lengths: HeapMappedArray<UInt32>
    let outOffsets: HeapMappedArray<UInt32>
    let outTargets: HeapMappedArray<UInt32>
    let inOffsets: HeapMappedArray<UInt32>
    let inSources: HeapMappedArray<UInt32>
    let memberOffsets: HeapMappedArray<UInt32>
    let members: HeapMappedArray<Int32>
    let lookup: HeapIDLookup
    let dominators: HeapMappedArray<Int32>
    let retained: HeapMappedArray<UInt64>
    let childOffsets: HeapMappedArray<UInt32>
    let children: HeapMappedArray<Int32>
    let pathParents: HeapMappedArray<Int32>
    let classRetained: HeapMappedArray<UInt64>
    let unreachable: HeapMappedArray<UInt64>
    let weaklyReachable: HeapMappedArray<UInt64>
    private let table: ClassTable
    private let fd: Int32
    private let sizes: HeapShallowSizes
    private let lock = NSLock()
    private var chainCache: [Int32: [HeapClass.Field]] = [:]
    private var sizesByLayout: [HeapObjectLayout: HeapShallowSizes] = [:]
    private var rootsByObject: [Int32: [HeapRoot]]?

    /// Objects a strong path from a GC root reaches, and their shallow bytes (under `layout`).
    public let reachableCount: Int
    public let reachableBytes: Int64
    /// Objects only `Reference.referent` links reach (weak, soft, phantom): not kept alive, but
    /// not garbage yet either. A soft-reference cache lives here.
    public let weaklyReachableCount: Int
    public let weaklyReachableBytes: Int64
    /// The rest: garbage the dump was written with (an out-of-memory dump is not collected first).
    public let unreachableCount: Int
    public let unreachableBytes: Int64

    /// Maps a finished index; `HeapIndexStore.openExisting` checks it is current first.
    public static func open(directory: URL, dump: URL) throws -> HeapIndex {
        let metaData = try Data(contentsOf: directory.appendingPathComponent(HeapIndexBuilder.Files.meta))
        let meta = try JSONDecoder().decode(HeapIndexMeta.self, from: metaData)
        return try HeapIndex(directory: directory, dump: dump, meta: meta)
    }

    private init(directory: URL, dump: URL, meta: HeapIndexMeta) throws {
        typealias F = HeapIndexBuilder.Files
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        self.directory = directory
        self.dumpURL = dump
        objectCount = meta.objectCount
        referenceCount = meta.edgeCount
        danglingReferences = meta.danglingReferences
        idSize = meta.idSize
        layout = HeapObjectLayout(headerSize: meta.layoutHeader, referenceSize: meta.layoutReference)
        buildSeconds = meta.buildSeconds
        let total = meta.objectCount + 1
        ids = try .open(url(F.ids), count: total)
        offsets = try .open(url(F.offsets), count: total)
        classIndexes = try .open(url(F.classes), count: total)
        kinds = try .open(url(F.kinds), count: total)
        lengths = try .open(url(F.lengths), count: total)
        outOffsets = try .open(url(F.outOffsets), count: total + 1)
        outTargets = try .open(url(F.outTargets), count: meta.edgeCount)
        inOffsets = try .open(url(F.inOffsets), count: total + 1)
        inSources = try .open(url(F.inSources), count: meta.edgeCount)
        memberOffsets = try .open(url(F.memberOffsets), count: meta.classCount + 1)
        members = try .open(url(F.members), count: meta.objectCount)
        lookup = try HeapIDLookup.open(ids: ids, directory: directory)
        table = try ClassTable.read(from: url(F.classTable))
        classes = table.entries
        mirrorGroup = table.mirrorGroup
        guard classes.count == meta.classCount else { throw HeapIndexError.corrupt("class count") }
        typealias D = HeapDominatorBuilder.Files
        dominators = try .open(url(D.dominators), count: total)
        retained = try .open(url(D.retained), count: total)
        childOffsets = try .open(url(D.childOffsets), count: total + 1)
        children = try .open(url(D.children), count: meta.reachableCount)
        pathParents = try .open(url(D.pathParents), count: total)
        classRetained = try .open(url(D.classRetained), count: max(meta.classCount, 1))
        unreachable = try .open(url(D.unreachable), count: meta.classCount * 2)
        weaklyReachable = try .open(url(D.weaklyReachable), count: meta.classCount * 2)
        weaklyReachableCount = meta.weaklyReachableCount
        weaklyReachableBytes = meta.weaklyReachableBytes
        reachableCount = meta.reachableCount
        reachableBytes = meta.reachableBytes
        unreachableCount = meta.unreachableCount
        unreachableBytes = meta.unreachableBytes

        var reader = try HeapBinaryReader(Data(contentsOf: url(F.roots)))
        var roots: [HeapRoot] = []
        let rootCount = Int(try reader.u32())
        roots.reserveCapacity(rootCount)
        for _ in 0..<rootCount {
            let kindIndex = Int(try reader.u8())
            let id = try reader.u64()
            let number = Int32(bitPattern: try reader.u32())
            let first = try reader.u32()
            let second = try reader.u32()
            roots.append(HeapRoot(
                kind: HprofRootKind.allCases[min(kindIndex, HprofRootKind.allCases.count - 1)], id: id,
                object: number > 0 ? number : nil, threadSerial: first, detail: second
            ))
        }
        self.roots = roots

        sizes = HeapShallowSizes(classes: table.entries, layout: layout)

        let fd = Darwin.open(dump.path, O_RDONLY)
        guard fd >= 0 else { throw HprofError.cannotOpen(String(cString: strerror(errno))) }
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }

    /// The dump file, open read-only, for reports that read many records in file order.
    var dumpDescriptor: Int32 { fd }

    // MARK: - Objects

    public func number(ofID id: UInt64) -> Int32? { lookup.number(of: id) }

    public func id(of n: Int32) -> UInt64 { ids[Int(n)] }

    public func kind(of n: Int32) -> HeapObjectKind {
        HeapObjectKind(rawValue: kinds[Int(n)]) ?? .instance
    }

    /// The object's class; for a class mirror, the class it describes.
    public func classIndex(of n: Int32) -> Int32 { classIndexes[Int(n)] }

    /// The group `instances(ofGroup:)` lists the object under: its class, or the mirror group.
    public func groupIndex(of n: Int32) -> Int32 {
        kind(of: n) == .classObject ? mirrorGroup : classIndex(of: n)
    }

    public func className(of n: Int32) -> String {
        switch kind(of: n) {
        case .superRoot: return "<root>"
        case .classObject: return "java.lang.Class"
        default:
            let index = Int(classIndex(of: n))
            return index >= 0 && index < classes.count ? classes[index].name : "<unknown class>"
        }
    }

    /// Array length; 0 for anything else.
    public func length(of n: Int32) -> Int {
        switch kind(of: n) {
        case .objectArray, .primitiveArray: return Int(lengths[Int(n)])
        default: return 0
        }
    }

    public func shallowSize(of n: Int32, layout override: HeapObjectLayout? = nil) -> Int {
        let calculator: HeapShallowSizes
        if let override, override != layout {
            lock.lock()
            if let cached = sizesByLayout[override] {
                calculator = cached
            } else {
                let made = HeapShallowSizes(classes: classes, layout: override)
                sizesByLayout[override] = made
                calculator = made
            }
            lock.unlock()
        } else {
            calculator = sizes
        }
        return calculator.size(kind: kinds[Int(n)], classIndex: classIndexes[Int(n)], length: lengths[Int(n)])
    }

    /// `java.util.HashMap @ 0x7f0a1b2c8`
    public func title(of n: Int32) -> String {
        guard n > 0 else { return "<root>" }
        if kind(of: n) == .classObject {
            return "class \(classes[Int(classIndex(of: n))].name) @ 0x\(String(id(of: n), radix: 16))"
        }
        return "\(className(of: n)) @ 0x\(String(id(of: n), radix: 16))"
    }

    // MARK: - References

    public func outbound(of n: Int32) -> [HeapEdge] {
        let start = Int(outOffsets[Int(n)])
        let end = Int(outOffsets[Int(n) + 1])
        return (start..<end).map { edge(outTargets[$0]) }
    }

    public func inboundCount(of n: Int32) -> Int {
        Int(inOffsets[Int(n) + 1]) - Int(inOffsets[Int(n)])
    }

    public func inbound(of n: Int32, range: Range<Int>) -> [HeapEdge] {
        let start = Int(inOffsets[Int(n)])
        let count = inboundCount(of: n)
        let clamped = range.clamped(to: 0..<count)
        return clamped.map { edge(inSources[start + $0]) }
    }

    @inline(__always)
    private func edge(_ stored: UInt32) -> HeapEdge {
        HeapEdge(object: Int32(bitPattern: stored & ~HeapIndexBuilder.weakBit), isWeak: stored & HeapIndexBuilder.weakBit != 0)
    }

    // MARK: - Who keeps what alive

    /// Whether a strong path from a root reaches the object (what dominators and retained sizes cover).
    public func isReachable(_ n: Int32) -> Bool { n == 0 || dominators[Int(n)] >= 0 }

    public enum Reachability: Sendable, Equatable {
        /// A strong path from a GC root reaches it: it is kept alive.
        case strong
        /// Only paths through a `Reference.referent` reach it: collectable, but not garbage yet.
        case weak
        /// Nothing reaches it: garbage the dump was written with.
        case unreachable
    }

    public func reachability(of n: Int32) -> Reachability {
        if isReachable(n) { return .strong }
        return pathParents[Int(n)] <= -2 ? .weak : .unreachable
    }

    /// Bytes that would be freed with the object: itself and everything only it keeps alive
    /// (under the index's `layout`). For the super-root, every reachable byte; 0 when unreachable.
    public func retainedSize(of n: Int32) -> Int64 { Int64(retained[Int(n)]) }

    /// The object's immediate dominator: 0 for one kept alive by several roots or by a root
    /// itself, nil for the super-root and for unreachable objects.
    public func dominator(of n: Int32) -> Int32? {
        let d = dominators[Int(n)]
        return d >= 0 ? d : nil
    }

    public func dominatorChildCount(of n: Int32) -> Int {
        Int(childOffsets[Int(n) + 1]) - Int(childOffsets[Int(n)])
    }

    /// What `n` alone keeps alive, directly: largest retained first.
    public func dominatorChildren(of n: Int32, range: Range<Int>) -> [Int32] {
        let start = Int(childOffsets[Int(n)])
        return range.clamped(to: 0..<dominatorChildCount(of: n)).map { children[start + $0] }
    }

    /// A class's retained size: its instances' retained sizes, an instance counted only when no
    /// dominator above it is of the same class (a linked list counts once).
    public func retainedSize(ofGroup group: Int32) -> Int64 {
        guard group >= 0, Int(group) < classes.count else { return 0 }
        return Int64(classRetained[Int(group)])
    }

    /// The shortest strong path from the object to a GC root: `[n, …, root]`; empty when no
    /// strong path exists. With `includingWeak`, an only weakly reachable object gets the path
    /// through its `Reference.referent` link (`isWeakLink` says which steps are weak).
    public func pathToRoot(of n: Int32, includingWeak: Bool = false, limit: Int = 1_000_000) -> [Int32] {
        guard n > 0 else { return [] }
        let first = pathParents[Int(n)]
        guard first >= 0 || (includingWeak && first <= -2) else { return [] }
        var path: [Int32] = [n]
        var current = n
        while path.count < limit {
            let stored = pathParents[Int(current)]
            let parent = stored >= 0 ? stored : -stored - 2
            guard stored != -1, parent > 0 else { break }
            current = parent
            path.append(current)
        }
        return path
    }

    /// Whether the step from `n` to the next object up its path is a `Reference.referent` link,
    /// or crosses one further up (an object reached only through a weak link).
    public func isWeakLink(_ n: Int32) -> Bool {
        n > 0 && pathParents[Int(n)] <= -2
    }

    /// The root records that name `n` (a thread, a Java frame, a sticky class…).
    public func roots(of n: Int32) -> [HeapRoot] {
        lock.lock()
        defer { lock.unlock() }
        if rootsByObject == nil {
            var map: [Int32: [HeapRoot]] = [:]
            for root in roots {
                if let object = root.object { map[object, default: []].append(root) }
            }
            rootsByObject = map
        }
        return rootsByObject?[n] ?? []
    }

    /// One line of a merged-paths tree: an object on the way from roots to the chosen objects,
    /// how many of them pass through it, at which depth (0 is a root).
    public struct PathNode: Sendable, Hashable, Identifiable {
        public let id: Int
        public let object: Int32
        public let depth: Int
        public let count: Int
        /// The chosen object itself (a leaf of the tree).
        public let isTarget: Bool
    }

    /// MAT's "Merge Shortest Paths to GC Roots": the paths of `objects` folded from the root side,
    /// the busiest branch first, at most `limit` lines.
    public func mergedPathsToRoots(of objects: [Int32], limit: Int = 2_000) -> [PathNode] {
        // Flat storage: a tree of objects owning their children is released one level per stack
        // frame, and paths thousands of objects deep overflow a background thread's stack.
        var nodeObject: [Int32] = [0]
        var nodeCount: [Int] = [0]
        var nodeIsTarget: [Bool] = [false]
        var nodeChildren: [[Int32: Int]] = [[:]]
        for n in objects where isReachable(n) {
            let path = pathToRoot(of: n)
            guard !path.isEmpty else { continue }
            var node = 0
            nodeCount[0] += 1
            for object in path.reversed() {
                if let next = nodeChildren[node][object] {
                    node = next
                } else {
                    let next = nodeObject.count
                    nodeObject.append(object)
                    nodeCount.append(0)
                    nodeIsTarget.append(false)
                    nodeChildren.append([:])
                    nodeChildren[node][object] = next
                    node = next
                }
                nodeCount[node] += 1
            }
            nodeIsTarget[node] = true
        }
        func ordered(_ node: Int) -> [Int] {
            nodeChildren[node].values.sorted { (nodeCount[$0], nodeObject[$1]) > (nodeCount[$1], nodeObject[$0]) }
        }
        var result: [PathNode] = []
        var stack: [(node: Int, depth: Int)] = ordered(0).reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast(), result.count < limit {
            result.append(PathNode(
                id: result.count, object: nodeObject[node], depth: depth, count: nodeCount[node], isTarget: nodeIsTarget[node]
            ))
            for child in ordered(node).reversed() { stack.append((child, depth + 1)) }
        }
        return result
    }

    /// Objects of one class (or array type) and their bytes.
    public struct ClassTotal: Sendable, Hashable, Identifiable, Codable {
        public let group: Int32
        public let name: String
        public let count: Int
        public let bytes: Int64
        public var id: Int32 { group }
    }

    /// What `n` keeps alive, by class (its dominator subtree, itself included), largest first.
    /// Walks at most `visitLimit` objects; `complete` says whether it saw them all.
    public func retainedClasses(of n: Int32, visitLimit: Int = 200_000_000) -> (classes: [ClassTotal], complete: Bool) {
        var counts: [Int32: (count: Int, bytes: Int64)] = [:]
        var stack: [Int32] = [n]
        var visited = 0
        while let v = stack.popLast() {
            if v != 0 {
                let g = groupIndex(of: v)
                counts[g, default: (0, 0)].count += 1
                counts[g, default: (0, 0)].bytes += Int64(shallowSize(of: v))
            }
            visited += 1
            if visited >= visitLimit { break }
            let start = Int(childOffsets[Int(v)])
            let end = Int(childOffsets[Int(v) + 1])
            if start < end { for index in start..<end { stack.append(children[index]) } }
        }
        let totals = counts.map { group, value in
            ClassTotal(group: group, name: classes[Int(group)].name, count: value.count, bytes: value.bytes)
        }
        return (totals.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }, stack.isEmpty)
    }

    /// The unreachable objects (garbage) by class, largest first.
    public func unreachableClasses(limit: Int = 200) -> [ClassTotal] {
        totals(unreachable, limit: limit)
    }

    /// The only weakly reachable objects by class, largest first.
    public func weaklyReachableClasses(limit: Int = 200) -> [ClassTotal] {
        totals(weaklyReachable, limit: limit)
    }

    private func totals(_ table: HeapMappedArray<UInt64>, limit: Int) -> [ClassTotal] {
        var totals: [ClassTotal] = []
        for g in 0..<classes.count where table[2 * g] > 0 {
            totals.append(ClassTotal(group: Int32(g), name: classes[g].name, count: Int(table[2 * g]), bytes: Int64(table[2 * g + 1])))
        }
        return Array(totals.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }.prefix(limit))
    }

    // MARK: - Instances

    public enum InstanceOrder: Sendable {
        case address
        /// By shallow size.
        case largestFirst
        /// By retained size: what each instance keeps alive.
        case largestRetainedFirst
    }

    public func instanceCount(ofGroup group: Int32) -> Int {
        guard group >= 0, Int(group) < classes.count else { return 0 }
        return Int(memberOffsets[Int(group) + 1]) - Int(memberOffsets[Int(group)])
    }

    /// Up to `limit` objects of a group. Largest-first keeps a bounded heap, so a group of ten
    /// million arrays costs one pass and `limit` slots.
    public func instances(ofGroup group: Int32, order: InstanceOrder = .largestFirst, limit: Int = 1_000) -> [Int32] {
        guard group >= 0, Int(group) < classes.count, limit > 0 else { return [] }
        let start = Int(memberOffsets[Int(group)])
        let end = Int(memberOffsets[Int(group) + 1])
        guard start < end else { return [] }
        let sameSize: Bool
        switch classes[Int(group)].kind {
        case .loaded, .unknown: sameSize = true
        case .primitiveArray, .classMirrors: sameSize = false
        }
        let isArrayClass = classes[Int(group)].name.hasSuffix("[]")
        if order == .address || (order == .largestFirst && sameSize && !isArrayClass) {
            let stop = limit >= end - start ? end : start + limit
            return (start..<stop).map { members[$0] }
        }
        // A min-heap of the `limit` largest (size, number), then sorted largest first.
        var heap: [(size: Int, n: Int32)] = []
        heap.reserveCapacity(min(limit, end - start))
        func less(_ a: (size: Int, n: Int32), _ b: (size: Int, n: Int32)) -> Bool {
            a.size != b.size ? a.size < b.size : a.n > b.n
        }
        func siftDown(_ start: Int) {
            var parent = start
            while true {
                let left = 2 * parent + 1
                guard left < heap.count else { return }
                var child = left
                if left + 1 < heap.count, less(heap[left + 1], heap[left]) { child = left + 1 }
                guard less(heap[child], heap[parent]) else { return }
                heap.swapAt(child, parent)
                parent = child
            }
        }
        func siftUp(_ index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard less(heap[child], heap[parent]) else { return }
                heap.swapAt(child, parent)
                child = parent
            }
        }
        for position in start..<end {
            let n = members[position]
            let entry = (size: order == .largestRetainedFirst ? Int(retained[Int(n)]) : shallowSize(of: n), n: n)
            if heap.count < limit {
                heap.append(entry)
                siftUp(heap.count - 1)
            } else if less(heap[0], entry) {
                heap[0] = entry
                siftDown(0)
            }
        }
        return heap.sorted { less($1, $0) }.map(\.n)
    }

    /// The group of a histogram row: its class, its primitive array type, or the class mirrors.
    public func groupIndex(for row: HeapClassRow) -> Int32? {
        switch row.kind {
        case .classObject:
            return mirrorGroup
        case .primitiveArray:
            guard let type = HprofBasicType.allCases.first(where: { $0.arrayName == row.name }) else { return nil }
            let index = table.primitiveArrayIndex[Int(type.rawValue)]
            return index >= 0 ? index : nil
        case .instance, .objectArray:
            guard let classID = row.classID else { return nil }
            return table.indexByID[classID]
        case .package:
            return nil
        }
    }

    public func classIndex(forClassID id: UInt64) -> Int32? { table.indexByID[id] }

    // MARK: - Contents

    /// Instance fields (the class's first, then each superclass's), a class's statics with its
    /// superclass and loader, or an array's first elements.
    public func fields(of n: Int32, elementLimit: Int = 1_000) throws -> [HeapField] {
        switch kind(of: n) {
        case .superRoot:
            return []
        case .instance:
            let chain = fieldChain(of: classIndex(of: n))
            let length = Int(lengths[Int(n)])
            let bytes = try read(offsets[Int(n)] + Int64(2 * idSize + 9), length)
            var result: [HeapField] = []
            var offset = 0
            for (position, field) in chain.enumerated() {
                let size = field.type.size(idSize: idSize)
                guard offset + size <= bytes.count else { break }
                let bits = bytes.withUnsafeBytes { HprofHeapWalker.readValue($0.baseAddress!, offset, size: size) }
                result.append(HeapField(id: position, name: field.name, type: field.type, value: value(bits, field.type)))
                offset += size
            }
            return result
        case .classObject:
            let entry = classes[Int(classIndex(of: n))]
            var result: [HeapField] = [
                HeapField(id: 0, name: "<superclass>", type: .object, value: value(entry.superID, .object)),
                HeapField(id: 1, name: "<class loader>", type: .object, value: value(entry.loaderID, .object))
            ]
            for (position, field) in entry.statics.enumerated() {
                result.append(HeapField(id: position + 2, name: "static \(field.name)", type: field.type, value: value(field.value, field.type)))
            }
            return result
        case .objectArray, .primitiveArray:
            return try elements(of: n, range: 0..<elementLimit)
        }
    }

    public func elements(of n: Int32, range: Range<Int>) throws -> [HeapField] {
        let count = length(of: n)
        let clamped = range.clamped(to: 0..<count)
        guard !clamped.isEmpty else { return [] }
        let type: HprofBasicType
        let start: Int64
        switch kind(of: n) {
        case .objectArray:
            type = .object
            start = offsets[Int(n)] + Int64(2 * idSize + 9)
        case .primitiveArray:
            guard case .primitiveArray(let elementType) = classes[Int(classIndex(of: n))].kind else { return [] }
            type = elementType
            start = offsets[Int(n)] + Int64(idSize + 10)
        default:
            return []
        }
        let size = type.size(idSize: idSize)
        let bytes = try read(start + Int64(clamped.lowerBound * size), clamped.count * size)
        return bytes.withUnsafeBytes { raw in
            clamped.enumerated().map { position, index in
                let bits = HprofHeapWalker.readValue(raw.baseAddress!, position * size, size: size)
                return HeapField(id: index, name: "[\(index)]", type: type, value: value(bits, type))
            }
        }
    }

    /// The raw bytes of a primitive array's first `limit` elements, and its element type.
    func primitiveArrayBytes(of n: Int32, limit: Int) throws -> (HprofBasicType, [UInt8])? {
        guard kind(of: n) == .primitiveArray,
              case .primitiveArray(let type) = classes[Int(classIndex(of: n))].kind else { return nil }
        let count = min(length(of: n), limit)
        let bytes = try read(offsets[Int(n)] + Int64(idSize + 10), count * type.size(idSize: idSize))
        return (type, bytes)
    }

    /// How `from` refers to `to`: a field name, `[i]`, `static NAME`, `<superclass>`; nil if not
    /// found within the first 100,000 elements of an array.
    public func referenceName(from: Int32, to: Int32) -> String? {
        if kind(of: from) == .objectArray {
            let count = min(length(of: from), 100_000)
            var start = 0
            while start < count {
                let page = (try? elements(of: from, range: start..<min(count, start + 4_096))) ?? []
                if let hit = page.first(where: { $0.value == .object(to) }) { return hit.name }
                start += 4_096
            }
            return nil
        }
        return (try? fields(of: from))?.first { $0.value == .object(to) }?.name
    }

    /// Named fields of an instance, by name (the subclass's wins), for the value previews.
    func field(_ name: String, of n: Int32) -> HeapValue? {
        guard kind(of: n) == .instance else { return nil }
        return (try? fields(of: n))?.first { $0.name == name }?.value
    }

    /// Whether the object's class is `name` or extends it.
    func isInstance(_ n: Int32, of name: String) -> Bool {
        guard kind(of: n) == .instance else { return false }
        var cursor = classIndex(of: n)
        var steps = 0
        while cursor >= 0, Int(cursor) < classes.count, steps < 64 {
            if classes[Int(cursor)].name == name { return true }
            cursor = classes[Int(cursor)].superIndex
            steps += 1
        }
        return false
    }

    /// A short rendering of what the object holds: a string's text, a boxed value, an enum's
    /// name, a collection's size, an array's length. Nil when there is nothing to say.
    public func preview(of n: Int32) -> String? {
        HeapValueFormatter.preview(of: n, in: self)
    }

    /// Bytes the index takes on disk.
    public var diskBytes: Int64 {
        HeapIndexStore.size(of: directory)
    }

    // MARK: - Helpers

    @inline(__always)
    private func value(_ bits: UInt64, _ type: HprofBasicType) -> HeapValue {
        HeapValue.decode(bits, type: type) { self.lookup.number(of: $0) }
    }

    private func fieldChain(of classIndex: Int32) -> [HeapClass.Field] {
        lock.lock()
        if let cached = chainCache[classIndex] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var chain: [HeapClass.Field] = []
        var cursor = classIndex
        var seen = Set<Int32>()
        while cursor >= 0, Int(cursor) < classes.count, seen.insert(cursor).inserted {
            chain.append(contentsOf: classes[Int(cursor)].fields)
            cursor = classes[Int(cursor)].superIndex
        }
        lock.lock()
        chainCache[classIndex] = chain
        lock.unlock()
        return chain
    }

    func read(_ offset: Int64, _ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let result = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw HprofError.truncated(at: offset + Int64(done)) }
            done += result
        }
        return bytes
    }
}
