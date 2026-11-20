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
    private let table: ClassTable
    private let fd: Int32
    /// Per class: primitive bytes and reference count of an instance (the whole chain).
    private let shapes: [(primitiveBytes: Int, references: Int)]
    private let classClassShape: (primitiveBytes: Int, references: Int)
    private let lock = NSLock()
    private var chainCache: [Int32: [HeapClass.Field]] = [:]

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

        var shapes: [(primitiveBytes: Int, references: Int)] = []
        shapes.reserveCapacity(table.entries.count)
        for index in table.entries.indices {
            var primitive = 0
            var references = 0
            var cursor = Int32(index)
            var seen = Set<Int32>()
            while cursor >= 0, Int(cursor) < table.entries.count, seen.insert(cursor).inserted {
                let entry = table.entries[Int(cursor)]
                for field in entry.fields {
                    if field.type == .object { references += 1 } else { primitive += field.type.size(idSize: 8) }
                }
                cursor = entry.superIndex
            }
            shapes.append((primitive, references))
        }
        self.shapes = shapes
        classClassShape = table.entries.firstIndex { $0.name == "java.lang.Class" && $0.kind == .loaded }
            .map { shapes[$0] } ?? (0, 0)

        let fd = Darwin.open(dump.path, O_RDONLY)
        guard fd >= 0 else { throw HprofError.cannotOpen(String(cString: strerror(errno))) }
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }

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
        let layout = override ?? layout
        let index = Int(classIndex(of: n))
        switch kind(of: n) {
        case .superRoot:
            return 0
        case .instance:
            guard index > 0, index < shapes.count, case .loaded = classes[index].kind else {
                return HeapObjectLayout.align(layout.headerSize + Int(lengths[Int(n)]))
            }
            return layout.instanceSize(primitiveBytes: shapes[index].primitiveBytes, references: shapes[index].references)
        case .objectArray:
            return layout.arraySize(length: Int(lengths[Int(n)]), elementSize: layout.referenceSize)
        case .primitiveArray:
            guard index >= 0, index < classes.count, case .primitiveArray(let type) = classes[index].kind else { return 0 }
            return layout.arraySize(length: Int(lengths[Int(n)]), elementSize: type.size(idSize: 8))
        case .classObject:
            var primitive = classClassShape.primitiveBytes
            var references = classClassShape.references
            if index >= 0, index < classes.count {
                for field in classes[index].statics {
                    if field.type == .object { references += 1 } else { primitive += field.type.size(idSize: 8) }
                }
            }
            return layout.instanceSize(primitiveBytes: primitive, references: references)
        }
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

    // MARK: - Instances

    public enum InstanceOrder: Sendable {
        case address
        case largestFirst
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
        if order == .address || (sameSize && !isArrayClass) {
            return (start..<min(end, start + limit)).map { members[$0] }
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
            let entry = (size: shallowSize(of: n), n: n)
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
