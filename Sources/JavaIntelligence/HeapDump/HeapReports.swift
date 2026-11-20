import Darwin
import Foundation

// MARK: - Threads

/// One frame of a thread's stack, with the objects its locals held (ROOT_JAVA_FRAME / ROOT_JNI_LOCAL
/// at this depth).
public struct HeapStackFrame: Codable, Sendable, Hashable {
    public let className: String
    public let method: String
    public let signature: String
    public let file: String?
    /// > 0 a line; -1 unknown, -2 compiled code, -3 native.
    public let line: Int32
    public let locals: [Int32]

    /// `java.lang.Thread.run(Thread.java:1583)`
    public var description: String {
        let place: String
        switch line {
        case let line where line > 0: place = "\(file ?? "Unknown Source"):\(line)"
        case -2: place = "Compiled frame"
        case -3: place = "Native Method"
        default: place = file ?? "Unknown Source"
        }
        return "\(className).\(method)(\(place))"
    }
}

/// A thread at the moment of the dump: its object, its stack, and locals the dump could not place
/// on a frame.
public struct HeapThread: Codable, Sendable, Hashable, Identifiable {
    /// The dump's thread serial.
    public let id: UInt32
    public let object: Int32?
    public let frames: [HeapStackFrame]
    public let unplacedLocals: [Int32]
}

enum HeapThreadBuilder {
    static let file = "threads.json"

    static func make(
        topLevel: HeapDumpCensus.TopLevel, roots: [HeapIndexBuilder.CollectorPart.Root], lookup: HeapIDLookup,
        fd: Int32, fileSize: Int64
    ) throws -> [HeapThread] {
        var threadObjects: [UInt32: (object: UInt64, trace: UInt32)] = [:]
        var locals: [UInt32: [UInt32: [Int32]]] = [:]
        for root in roots {
            switch root.kind {
            case .threadObject:
                threadObjects[root.first] = (root.id, root.second)
            case .javaFrame, .jniLocal:
                guard let n = lookup.number(of: root.id) else { continue }
                locals[root.first, default: [:]][root.second, default: []].append(n)
            default:
                break
            }
        }
        var nameIDs = Set<UInt64>()
        for (_, thread) in threadObjects {
            for frameID in topLevel.traces[thread.trace]?.frameIDs ?? [] {
                guard let frame = topLevel.frames[frameID] else { continue }
                nameIDs.formUnion([frame.methodNameID, frame.signatureID, frame.sourceFileID])
            }
        }
        let names = try HeapDumpCensus.readStrings(fd: fd, fileSize: fileSize, ids: nameIDs, topLevel: topLevel)
        let classNames = try HeapDumpCensus.readClassNames(fd: fd, fileSize: fileSize, topLevel: topLevel)
        return threadObjects.keys.sorted().map { serial in
            let thread = threadObjects[serial]!
            var byDepth = locals[serial] ?? [:]
            let frameIDs = topLevel.traces[thread.trace]?.frameIDs ?? []
            let frames = frameIDs.enumerated().map { depth, frameID -> HeapStackFrame in
                let frame = topLevel.frames[frameID]
                let className = frame.flatMap { topLevel.classSerials[$0.classSerial] }.flatMap { classNames[$0] } ?? "<unknown class>"
                return HeapStackFrame(
                    className: className,
                    method: frame.flatMap { names[$0.methodNameID] } ?? "<unknown>",
                    signature: frame.flatMap { names[$0.signatureID] } ?? "",
                    file: frame.flatMap { $0.sourceFileID == 0 ? nil : names[$0.sourceFileID] },
                    line: frame?.line ?? -1,
                    locals: byDepth.removeValue(forKey: UInt32(depth)) ?? []
                )
            }
            return HeapThread(
                id: serial, object: lookup.number(of: thread.object), frames: frames,
                unplacedLocals: byDepth.values.flatMap { $0 }.sorted()
            )
        }
    }
}

/// What a thread was doing, from `threadStatus` (on `Thread` up to JDK 18, on its `holder` since).
public enum HeapThreadState: String, Sendable {
    case new = "NEW"
    case runnable = "RUNNABLE"
    case blocked = "BLOCKED"
    case waiting = "WAITING"
    case timedWaiting = "TIMED_WAITING"
    case terminated = "TERMINATED"

    /// `jdk.internal.misc.VM.toThreadState`.
    init(jvmtiStatus status: Int32) {
        if status & 0x4 != 0 { self = .runnable }
        else if status & 0x400 != 0 { self = .blocked }
        else if status & 0x10 != 0 { self = .waiting }
        else if status & 0x20 != 0 { self = .timedWaiting }
        else if status & 0x2 != 0 { self = .terminated }
        else if status & 0x1 == 0 { self = .new }
        else { self = .runnable }
    }
}

extension HeapIndex {
    /// The dump's threads, ordered by serial.
    public func threads() -> [HeapThread] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(HeapThreadBuilder.file)),
              let threads = try? JSONDecoder().decode([HeapThread].self, from: data) else { return [] }
        return threads
    }

    /// A thread object's name.
    public func threadName(_ object: Int32) -> String? {
        guard case .object(let name)? = field("name", of: object) else { return nil }
        return HeapValueFormatter.string(name, in: self)
    }

    public func threadState(_ object: Int32) -> HeapThreadState? {
        if case .int(let status)? = field("threadStatus", of: object) { return HeapThreadState(jvmtiStatus: status) }
        if case .object(let holder)? = field("holder", of: object), case .int(let status)? = field("threadStatus", of: holder) {
            return HeapThreadState(jvmtiStatus: status)
        }
        return nil
    }
}

// MARK: - Leak suspects

/// A problem suspect, after Eclipse MAT: one object, or the instances of one class together, that
/// keep at least the threshold of the live heap alive, with where the memory accumulates below it.
public struct HeapLeakSuspect: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case object
        case classGroup
    }

    public var id: String { "\(kind.rawValue)-\(object ?? -1)-\(group)" }
    public let kind: Kind
    /// The object (one-object suspect) or the largest instance (class group).
    public let object: Int32?
    public let group: Int32
    public let className: String
    public let instanceCount: Int
    public let retainedBytes: Int64
    /// Of the live (strongly reachable) heap, 0...1.
    public let share: Double
    public let loaderTitle: String?
    /// The deepest object below the suspect still holding most of its memory; nil when that is the suspect.
    public let accumulation: Int32?
    public let accumulationTitle: String?
    public let accumulationRetained: Int64
    /// What the accumulation point keeps alive directly, and the most common class among them.
    public let accumulationChildCount: Int
    public let accumulationChildClass: String?
    public let accumulationChildClassCount: Int
    /// The suspect's path to a GC root (suspect first), and the root's kinds.
    public let path: [Int32]
    public let rootKinds: [String]
    public let biggestClasses: [HeapIndex.ClassTotal]
    public let summary: String
}

public enum HeapLeakSuspects {
    /// Suspects keeping at least `threshold` of the live heap alive, largest first.
    public static func find(in index: HeapIndex, threshold: Double = 0.1) -> [HeapLeakSuspect] {
        let live = max(index.reachableBytes, 1)
        let minimum = Int64(Double(live) * threshold)
        var suspects: [HeapLeakSuspect] = []
        var reported = Set<Int32>()
        let topCount = index.dominatorChildCount(of: 0)
        // Single objects: top-level dominators are sorted, so stop at the first under the threshold.
        var position = 0
        var byClass: [Int32: (count: Int, bytes: Int64, largest: Int32)] = [:]
        while position < topCount {
            let page = index.dominatorChildren(of: 0, range: position..<(position + 4_096))
            for n in page {
                let retained = index.retainedSize(of: n)
                if retained >= minimum {
                    suspects.append(describe(object: n, group: index.groupIndex(of: n), count: 1, retained: retained, live: live, in: index))
                    reported.insert(n)
                } else {
                    let g = index.groupIndex(of: n)
                    if let entry = byClass[g] {
                        byClass[g] = (entry.count + 1, entry.bytes + retained, entry.largest)
                    } else {
                        byClass[g] = (1, retained, n)
                    }
                }
            }
            position += page.count
            if page.isEmpty { break }
        }
        // Classes whose many top-level instances add up past the threshold.
        for (group, total) in byClass where total.count > 1 && total.bytes >= minimum {
            suspects.append(describe(object: total.largest, group: group, count: total.count, retained: total.bytes, live: live, in: index))
        }
        return suspects.sorted { $0.retainedBytes > $1.retainedBytes }
    }

    static func describe(object n: Int32, group: Int32, count: Int, retained: Int64, live: Int64, in index: HeapIndex) -> HeapLeakSuspect {
        let className = index.classes[Int(group)].name
        let share = Double(retained) / Double(live)
        // Down the heaviest child while it keeps at least 80 % of its parent. Only for one object:
        // a class group's memory is spread over its instances, so no single point holds it.
        var accumulation = n
        while count == 1, let child = index.dominatorChildren(of: accumulation, range: 0..<1).first,
              Double(index.retainedSize(of: child)) >= 0.8 * Double(index.retainedSize(of: accumulation)) {
            accumulation = child
        }
        var childCount = 0
        var childClass: String?
        var childClassCount = 0
        if count == 1 {
            childCount = index.dominatorChildCount(of: accumulation)
            var tally: [Int32: Int] = [:]
            var position = 0
            while position < childCount {
                let page = index.dominatorChildren(of: accumulation, range: position..<(position + 65_536))
                for child in page { tally[index.groupIndex(of: child), default: 0] += 1 }
                position += page.count
                if page.isEmpty { break }
            }
            if let (g, number) = tally.max(by: { $0.value < $1.value }) {
                childClass = index.classes[Int(g)].name
                childClassCount = number
            }
        }
        let loader = loaderTitle(of: n, in: index)
        let path = index.pathToRoot(of: n)
        let rootKinds = Array(Set(path.last.map { index.roots(of: $0).map(\.kind.rawValue) } ?? [])).sorted()
        let biggest = count == 1 ? Array(index.retainedClasses(of: n).classes.prefix(5)) : []
        let size = ByteCountFormatter.string(fromByteCount: retained, countStyle: .memory)
        let percent = String(format: "%.1f%%", share * 100)
        var text = count == 1
            ? "One instance of \(className)\(loader.map { " loaded by \($0)" } ?? "") occupies \(size) (\(percent)) of the live heap."
            : "\(count.formatted()) instances of \(className)\(loader.map { ", loaded by \($0)," } ?? "") occupy \(size) (\(percent)) of the live heap."
        if accumulation != n {
            text += " The memory is accumulated in one instance of \(index.className(of: accumulation))"
            if let childClass, childCount > 0 {
                text += ", which keeps \(childCount.formatted()) objects alive directly, \(childClassCount == childCount ? "all" : "\(childClassCount.formatted()) of them") \(childClass)."
            } else {
                text += "."
            }
        }
        if count > 1 {
            text += " The largest one keeps \(ByteCountFormatter.string(fromByteCount: index.retainedSize(of: n), countStyle: .memory)) alive."
        }
        if path.count > 1 {
            let chain = compactChain(path.reversed().map { simpleName(index.className(of: $0)) })
            text += " \(count == 1 ? "Held" : "The largest is held") from a GC root (\(rootKinds.joined(separator: ", "))) through \(chain)."
        }
        return HeapLeakSuspect(
            kind: count == 1 ? .object : .classGroup, object: n, group: group, className: className,
            instanceCount: count, retainedBytes: retained, share: share, loaderTitle: loader,
            accumulation: accumulation == n ? nil : accumulation,
            accumulationTitle: accumulation == n ? nil : index.title(of: accumulation),
            accumulationRetained: index.retainedSize(of: accumulation),
            accumulationChildCount: childCount, accumulationChildClass: childClass, accumulationChildClassCount: childClassCount,
            path: path, rootKinds: rootKinds, biggestClasses: biggest, summary: text
        )
    }

    static func loaderTitle(of n: Int32, in index: HeapIndex) -> String? {
        let classIndex = Int(index.classIndex(of: n))
        guard classIndex >= 0, classIndex < index.classes.count else { return nil }
        let loader = index.classes[classIndex].loaderID
        guard loader != 0, let number = index.number(ofID: loader) else { return loader == 0 ? "the bootstrap loader" : nil }
        return index.title(of: number)
    }

    /// `A → B → B → B → C` becomes `A → B ×3 → C`; a chain still longer than eight steps keeps its
    /// first three and last three.
    static func compactChain(_ names: [String]) -> String {
        var steps: [String] = []
        var position = 0
        while position < names.count {
            var end = position + 1
            while end < names.count, names[end] == names[position] { end += 1 }
            let run = end - position
            steps.append(run > 1 ? "\(names[position]) ×\(run.formatted())" : names[position])
            position = end
        }
        if steps.count > 8 {
            steps = Array(steps.prefix(3)) + ["… \((steps.count - 6).formatted()) more …"] + Array(steps.suffix(3))
        }
        return steps.joined(separator: " → ")
    }

    static func simpleName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[name.index(after: dot)...])
    }
}

// MARK: - Inspections

/// Strings whose text another live string already holds, grouped by text.
public struct HeapDuplicateStrings: Codable, Sendable {
    public struct Group: Codable, Sendable, Hashable, Identifiable {
        public var id: Int32 { example }
        public let text: String
        public let count: Int
        /// What all but one copy cost: their `String` objects, and their arrays when not shared.
        public let wastedBytes: Int64
        public let example: Int32
    }

    public let stringCount: Int
    public let distinctCount: Int
    public let wastedBytes: Int64
    public let groups: [Group]
}

/// Collections holding a backing array they do not use.
public struct HeapWastedCollections: Codable, Sendable {
    public struct Row: Codable, Sendable, Hashable, Identifiable {
        public var id: String { "\(className)-\(problem)" }
        public let className: String
        /// "empty" (no elements, an allocated array) or "sparse" (under a quarter of its array used).
        public let problem: String
        public let count: Int
        public let wastedBytes: Int64
        public let examples: [Int32]
    }

    public let wastedBytes: Int64
    public let rows: [Row]
}

/// Primitive arrays of 1 KB or more holding nothing but zeros.
public struct HeapZeroArrays: Codable, Sendable {
    public struct Row: Codable, Sendable, Hashable, Identifiable {
        public var id: String { className }
        public let className: String
        public let count: Int
        public let bytes: Int64
        public let examples: [Int32]
    }

    public let bytes: Int64
    public let rows: [Row]
}

public enum HeapInspections {
    /// Results are saved beside the index, so a second look costs nothing.
    static func cached<T: Codable>(_ name: String, in index: HeapIndex, _ compute: () throws -> T) rethrows -> T {
        let url = index.directory.appendingPathComponent("report-\(name).json")
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        let value = try compute()
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
        return value
    }

    public static func duplicateStrings(in index: HeapIndex, limit: Int = 100) throws -> HeapDuplicateStrings {
        try cached("duplicate-strings", in: index) {
            guard let stringClass = index.classes.firstIndex(where: { $0.name == "java.lang.String" && $0.kind == .loaded }) else {
                return HeapDuplicateStrings(stringCount: 0, distinctCount: 0, wastedBytes: 0, groups: [])
            }
            // One flat entry per live string: (contents hash, value array, string). Sorted by array
            // to hash each array once in file order, then by hash to find the copies. No set or
            // dictionary per group: ten million strings stay a few flat arrays.
            struct Entry {
                var hash: UInt64
                var array: Int32
                var string: Int32
            }
            var entries: [Entry] = []
            for n in index.instances(ofGroup: Int32(stringClass), order: .address, limit: .max) where index.isReachable(n) {
                if let array = index.outbound(of: n).first(where: { index.kind(of: $0.object) == .primitiveArray })?.object {
                    entries.append(Entry(hash: 0, array: array, string: n))
                }
            }
            try Task.checkCancellation()
            entries.sort { $0.array < $1.array }
            let reader = HprofByteReader(fd: index.dumpDescriptor, start: 0, end: Int64.max, capacity: 4 << 20)
            var previous: (array: Int32, hash: UInt64) = (-1, 0)
            for position in entries.indices {
                if position & 0xFFFF == 0 { try Task.checkCancellation() }
                let array = entries[position].array
                if array == previous.array {
                    entries[position].hash = previous.hash
                    continue
                }
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                if case .primitiveArray(let type) = index.classes[Int(index.classIndex(of: array))].kind {
                    let bytes = index.length(of: array) * type.size(idSize: index.idSize)
                    hash ^= UInt64(type.rawValue) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bytes)
                    reader.seek(to: index.offsets[Int(array)] + Int64(index.idSize + 10))
                    if bytes > 0, let p = try? reader.peek(bytes) {
                        for byte in UnsafeRawBufferPointer(start: p, count: bytes) { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
                    }
                }
                entries[position].hash = hash
                previous = (array, hash)
            }
            try Task.checkCancellation()
            entries.sort { ($0.hash, $0.array, $0.string) < ($1.hash, $1.array, $1.string) }
            var wasted: Int64 = 0
            var distinct = 0
            var found: [HeapDuplicateStrings.Group] = []
            var start = 0
            while start < entries.count {
                var end = start + 1
                var arrays = 1
                while end < entries.count, entries[end].hash == entries[start].hash {
                    if entries[end].array != entries[end - 1].array { arrays += 1 }
                    end += 1
                }
                distinct += 1
                let count = end - start
                if count > 1 {
                    let example = entries[start].string
                    let waste = Int64(count - 1) * Int64(index.shallowSize(of: example))
                        + Int64(arrays - 1) * Int64(index.shallowSize(of: entries[start].array))
                    wasted += waste
                    found.append(.init(text: "", count: count, wastedBytes: waste, example: example))
                }
                start = end
            }
            let top = found.sorted { ($0.wastedBytes, $0.example) > ($1.wastedBytes, $1.example) }.prefix(limit).map { group in
                HeapDuplicateStrings.Group(
                    text: HeapValueFormatter.string(group.example, in: index) ?? "", count: group.count,
                    wastedBytes: group.wastedBytes, example: group.example
                )
            }
            let stringCount = entries.count
            return HeapDuplicateStrings(stringCount: stringCount, distinctCount: distinct, wastedBytes: wasted, groups: Array(top))
        }
    }

    /// The collections checked, and the fields that say how full they are.
    static let collections: [(name: String, size: String, array: String, sparse: Bool)] = [
        ("java.util.ArrayList", "size", "elementData", true),
        ("java.util.HashMap", "size", "table", false),
        ("java.util.LinkedHashMap", "size", "table", false),
        ("java.util.Hashtable", "count", "table", false),
        ("java.util.concurrent.ConcurrentHashMap", "baseCount", "table", false),
        ("java.util.Vector", "elementCount", "elementData", true),
        ("java.util.ArrayDeque", "", "elements", false)
    ]

    public static func wastedCollections(in index: HeapIndex, examples: Int = 20) throws -> HeapWastedCollections {
        try cached("wasted-collections", in: index) {
            var rows: [HeapWastedCollections.Row] = []
            for spec in collections {
                guard let group = index.classes.firstIndex(where: { $0.name == spec.name && $0.kind == .loaded }) else { continue }
                var empty = (count: 0, bytes: Int64(0), examples: [Int32]())
                var sparse = (count: 0, bytes: Int64(0), examples: [Int32]())
                for (position, n) in index.instances(ofGroup: Int32(group), order: .address, limit: .max).enumerated() where index.isReachable(n) {
                    if position & 0xFFFF == 0 { try Task.checkCancellation() }
                    guard let fields = try? index.fields(of: n),
                          let array = fields.first(where: { $0.name == spec.array })?.value.objectNumber else { continue }
                    let length = index.length(of: array)
                    guard length > 0 else { continue }
                    var size = -1
                    switch fields.first(where: { $0.name == spec.size })?.value {
                    case .int(let value)?: size = Int(value)
                    case .long(let value)?: size = Int(value)
                    default: break
                    }
                    if spec.name == "java.util.concurrent.ConcurrentHashMap",
                       fields.first(where: { $0.name == "counterCells" })?.value.objectNumber != nil {
                        continue  // the size is spread over counter cells
                    }
                    if size == 0 {
                        empty.count += 1
                        empty.bytes += Int64(index.shallowSize(of: array))
                        if empty.examples.count < examples { empty.examples.append(n) }
                    } else if spec.sparse, size > 0, length >= 16, size * 4 < length {
                        sparse.count += 1
                        sparse.bytes += Int64((length - size) * index.layout.referenceSize)
                        if sparse.examples.count < examples { sparse.examples.append(n) }
                    }
                }
                if empty.count > 0 {
                    rows.append(.init(className: spec.name, problem: "empty", count: empty.count, wastedBytes: empty.bytes, examples: empty.examples))
                }
                if sparse.count > 0 {
                    rows.append(.init(className: spec.name, problem: "sparse", count: sparse.count, wastedBytes: sparse.bytes, examples: sparse.examples))
                }
            }
            rows.sort { $0.wastedBytes > $1.wastedBytes }
            return HeapWastedCollections(wastedBytes: rows.reduce(0) { $0 + $1.wastedBytes }, rows: rows)
        }
    }

    public static func zeroArrays(in index: HeapIndex, minimumBytes: Int = 1024, examples: Int = 20) throws -> HeapZeroArrays {
        try cached("zero-arrays", in: index) {
            var rows: [HeapZeroArrays.Row] = []
            let reader = HprofByteReader(fd: index.dumpDescriptor, start: 0, end: Int64.max, capacity: 4 << 20)
            for (group, entry) in index.classes.enumerated() {
                guard case .primitiveArray(let type) = entry.kind else { continue }
                let size = type.size(idSize: index.idSize)
                var count = 0
                var bytes: Int64 = 0
                var found: [(Int32, Int)] = []
                for (position, n) in index.instances(ofGroup: Int32(group), order: .address, limit: .max).enumerated() {
                    if position & 0xFFFF == 0 { try Task.checkCancellation() }
                    let length = index.length(of: n) * size
                    guard length >= minimumBytes, index.isReachable(n) else { continue }
                    var isZero = true
                    var done = 0
                    var position = index.offsets[Int(n)] + Int64(index.idSize + 10)
                    while done < length, isZero {
                        let chunk = min(length - done, 1 << 20)
                        reader.seek(to: position)
                        guard let p = try? reader.peek(chunk) else { isZero = false; break }
                        let words = chunk / 8
                        let raw = UnsafeRawBufferPointer(start: p, count: chunk)
                        for word in 0..<words where raw.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self) != 0 {
                            isZero = false
                            break
                        }
                        if isZero { for byte in raw[(words * 8)...] where byte != 0 { isZero = false; break } }
                        done += chunk
                        position += Int64(chunk)
                    }
                    guard isZero else { continue }
                    count += 1
                    bytes += Int64(index.shallowSize(of: n))
                    found.append((n, length))
                }
                guard count > 0 else { continue }
                let largest = found.sorted { $0.1 > $1.1 }.prefix(examples).map(\.0)
                rows.append(.init(className: entry.name, count: count, bytes: bytes, examples: largest))
            }
            rows.sort { $0.bytes > $1.bytes }
            return HeapZeroArrays(bytes: rows.reduce(0) { $0 + $1.bytes }, rows: rows)
        }
    }
}
