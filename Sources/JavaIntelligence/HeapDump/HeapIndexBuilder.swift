import Darwin
import Foundation

/// Builds the object index of a heap dump (phase 2 of `docs/HEAP_DUMP_PLAN.md`): every object
/// numbered densely in id order (number 0 is the super-root of phase 3), its record's offset,
/// class and length, every reference in both directions, and each class's instances. Arrays are
/// `mmap`ed files in `directory`, so memory stays bounded whatever the dump's size; the index is
/// marked complete only at the end, so a cancelled or failed build is never mistaken for one.
public enum HeapIndexBuilder {
    public struct Progress: Sendable, Equatable {
        public enum Phase: String, Sendable {
            case readingClasses = "Reading classes"
            case recordingObjects = "Recording objects"
            case sorting = "Sorting objects"
            case followingReferences = "Following references"
            case linkingReferrers = "Linking referrers"
            case groupingInstances = "Grouping instances"
            case dominators = "Finding what keeps what alive"
        }

        public let phase: Phase
        public let fraction: Double

        public init(phase: Phase, fraction: Double) {
            self.phase = phase
            self.fraction = fraction
        }
    }

    /// Format of what is written; a different number makes `HeapIndexStore` rebuild.
    public static let formatVersion = 4

    /// Bytes of disk the build needs at its peak: per object about 130 (final arrays, the sort's
    /// records, the dominator pass's working arrays), per possible reference 12. Generous on purpose.
    public static func estimatedPeakBytes(objectCount: Int, referenceSlots: Int) -> Int64 {
        Int64(objectCount) * 130 + Int64(referenceSlots) * 12 + (64 << 20)
    }

    public static func build(
        dump url: URL, into directory: URL, layout: HeapObjectLayout,
        maxConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        workItemBytes: Int64 = 64 << 20,
        checkFreeSpace: Bool = true,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> HeapIndex {
        let started = Date()
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: directory) } }

        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw HprofError.cannotOpen(String(cString: strerror(errno))) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw HprofError.cannotOpen(String(cString: strerror(errno))) }
        let fileSize = Int64(info.st_size)
        var headBytes = [UInt8](repeating: 0, count: 64)
        let headCount = headBytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 64, 0) }
        let header = try HprofHeader.parse(Data(headBytes.prefix(max(headCount, 0))))
        let I = header.idSize

        // Pass 1: top-level records, then class dumps and roots with each chunk's object count.
        progress(Progress(phase: .readingClasses, fraction: 0))
        let topLevel = try HeapDumpCensus.scanTopLevel(fd: fd, fileSize: fileSize, header: header)
        let items = HeapDumpCensus.workItems(topLevel.segments, target: workItemBytes)
        let collected: [CollectorPart] = try await parallel(items.count, maxConcurrency) { index in
            var visitor = CollectorVisitor()
            try walk(items[index], fd: fd, idSize: I, visitor: &visitor)
            return visitor.part
        }
        try Task.checkCancellation()
        let objectCount = collected.reduce(0) { $0 + $1.objects }
        guard objectCount < Int(Int32.max) - 1 else { throw HeapIndexError.tooLarge("\(objectCount) objects, more than 2^31") }
        if checkFreeSpace {
            let slots = collected.reduce(0) { $0 + $1.referenceSlots }
            let needed = estimatedPeakBytes(objectCount: objectCount, referenceSlots: slots)
            if let available = HeapIndexStore.availableBytes(at: directory), available < needed {
                throw HeapIndexError.notEnoughSpace(needed: needed, available: available)
            }
        }

        var records: [HprofClassDumpRecord] = []
        var recordOffsets: [Int64] = []
        var roots: [CollectorPart.Root] = []
        for part in collected {
            records.append(contentsOf: part.classes)
            recordOffsets.append(contentsOf: part.classOffsets)
            roots.append(contentsOf: part.roots)
        }
        let classTable = try ClassTable.make(
            records: records, offsets: recordOffsets, fd: fd, fileSize: fileSize, topLevel: topLevel, idSize: I
        )
        try Task.checkCancellation()
        progress(Progress(phase: .recordingObjects, fraction: 0.08))

        // Pass 2: one record per object, each chunk sorted by id.
        var startList: [Int] = []
        var running = 0
        for part in collected {
            startList.append(running)
            running += part.objects
        }
        let starts = startList
        let recordFile = try HeapMappedArray<ObjectRecord>.create(directory.appendingPathComponent("records.tmp"), count: objectCount)
        let classIndexByID = classTable.indexByID
        let primitiveIndex = classTable.primitiveArrayIndex
        _ = try await parallel(items.count, maxConcurrency) { index -> Int in
            var visitor = RecordVisitor(
                records: recordFile, next: starts[index], classIndexByID: classIndexByID, primitiveIndex: primitiveIndex
            )
            try walk(items[index], fd: fd, idSize: I, visitor: &visitor)
            var slice = UnsafeMutableBufferPointer(rebasing: recordFile.buffer[starts[index]..<visitor.next])
            if !isSorted(slice) { slice.sort { $0.id < $1.id } }
            return 0
        }
        try Task.checkCancellation()
        progress(Progress(phase: .sorting, fraction: 0.3))

        // Merge the sorted chunks: object numbers 1...N in id order.
        let total = objectCount + 1
        let ids = try HeapMappedArray<UInt64>.create(directory.appendingPathComponent(Files.ids), count: total)
        let offsets = try HeapMappedArray<Int64>.create(directory.appendingPathComponent(Files.offsets), count: total)
        let classes = try HeapMappedArray<Int32>.create(directory.appendingPathComponent(Files.classes), count: total)
        let kinds = try HeapMappedArray<UInt8>.create(directory.appendingPathComponent(Files.kinds), count: total)
        let lengths = try HeapMappedArray<UInt32>.create(directory.appendingPathComponent(Files.lengths), count: total)
        kinds[0] = HeapObjectKind.superRoot.rawValue
        classes[0] = -1
        merge(
            recordFile, runs: zip(starts, collected.map(\.objects)).map { $0..<($0 + $1) },
            ids: ids, offsets: offsets, classes: classes, kinds: kinds, lengths: lengths
        )
        try? fm.removeItem(at: recordFile.url)
        let lookup = try HeapIDLookup.build(ids: ids, directory: directory)
        try Task.checkCancellation()
        progress(Progress(phase: .followingReferences, fraction: 0.4))

        // Pass 3: references, in parallel by ranges of object numbers.
        let outOffsets = try HeapMappedArray<UInt32>.create(directory.appendingPathComponent(Files.outOffsets), count: total + 1)
        let ranges = numberRanges(total: total, parts: max(1, maxConcurrency) * 8)
        let counter = HeapDumpCensus.ByteCounter()
        let layouts = classTable.referenceLayouts(idSize: I)
        let edgeParts: [EdgePart] = try await parallel(ranges.count, maxConcurrency) { index in
            let part = try followReferences(
                ranges[index], fd: fd, fileSize: fileSize, idSize: I, lookup: lookup, offsets: offsets,
                classes: classes, kinds: kinds, lengths: lengths, layouts: layouts, classTable: classTable,
                degrees: outOffsets, temp: directory.appendingPathComponent("edges-\(index).tmp")
            )
            let done = counter.add(Int64(ranges[index].count))
            progress(Progress(phase: .followingReferences, fraction: 0.4 + 0.25 * Double(done) / Double(total)))
            return part
        }
        try Task.checkCancellation()
        // Degrees sit at index n + 1; a running sum turns them into offsets.
        var edgeTotal: UInt64 = 0
        for n in 0..<total {
            edgeTotal += UInt64(outOffsets[n + 1])
            guard edgeTotal < UInt64(UInt32.max) else { throw HeapIndexError.tooLarge("more than 2^32 references") }
            outOffsets[n + 1] = UInt32(edgeTotal)
        }
        let edgeCount = Int(edgeTotal)
        let outTargets = try HeapMappedArray<UInt32>.create(directory.appendingPathComponent(Files.outTargets), count: edgeCount)
        var base = 0
        for part in edgeParts {
            if part.count > 0 { try copy(part.file, count: part.count, into: outTargets, at: base) }
            base += part.count
            try? fm.removeItem(at: part.file)
        }
        let dangling = edgeParts.reduce(0) { $0 + $1.dangling }
        try Task.checkCancellation()
        progress(Progress(phase: .linkingReferrers, fraction: 0.66))

        // Referrers: the transpose of the references.
        let inOffsets = try HeapMappedArray<UInt32>.create(directory.appendingPathComponent(Files.inOffsets), count: total + 1)
        let inSources = try HeapMappedArray<UInt32>.create(directory.appendingPathComponent(Files.inSources), count: edgeCount)
        try transpose(outOffsets: outOffsets, outTargets: outTargets, total: total, inOffsets: inOffsets, inSources: inSources, directory: directory)
        try Task.checkCancellation()
        progress(Progress(phase: .groupingInstances, fraction: 0.7))

        // Each class's objects, in number order.
        let groupCount = classTable.entries.count
        let memberOffsets = try HeapMappedArray<UInt32>.create(directory.appendingPathComponent(Files.memberOffsets), count: groupCount + 1)
        let members = try HeapMappedArray<Int32>.create(directory.appendingPathComponent(Files.members), count: objectCount)
        groupMembers(total: total, classes: classes, kinds: kinds, mirrorGroup: classTable.mirrorGroup,
                     memberOffsets: memberOffsets, members: members, groupCount: groupCount)

        try Task.checkCancellation()
        progress(Progress(phase: .dominators, fraction: 0.72))

        // Who keeps what alive: dominators, retained sizes, paths to roots, the unreachable.
        let rootNumbers = roots.compactMap { lookup.number(of: $0.id) }
        let facts = try HeapDominatorBuilder.build(
            total: total, roots: rootNumbers, outOffsets: outOffsets, outTargets: outTargets,
            inOffsets: inOffsets, inSources: inSources, kinds: kinds, classes: classes, lengths: lengths,
            sizes: HeapShallowSizes(classes: classTable.entries, layout: layout), groupCount: groupCount,
            mirrorGroup: classTable.mirrorGroup, directory: directory
        ) { fraction in progress(Progress(phase: .dominators, fraction: 0.72 + 0.27 * fraction)) }

        let written: [any HeapFlushable] = [ids, offsets, classes, kinds, lengths, outOffsets, outTargets, inOffsets, inSources, memberOffsets, members]
        for array in written { try array.flushToDisk() }
        try classTable.write(to: directory.appendingPathComponent(Files.classTable))
        try writeRoots(roots, lookup: lookup, to: directory.appendingPathComponent(Files.roots))
        let threads = try HeapThreadBuilder.make(topLevel: topLevel, roots: roots, lookup: lookup, fd: fd, fileSize: fileSize)
        try JSONEncoder().encode(threads).write(to: directory.appendingPathComponent(HeapThreadBuilder.file), options: .atomic)
        let meta = HeapIndexMeta(
            formatVersion: formatVersion, dump: try HeapIndexMeta.DumpStamp(url),
            idSize: I, objectCount: objectCount, edgeCount: edgeCount, classCount: groupCount,
            rootCount: roots.count, layoutHeader: layout.headerSize, layoutReference: layout.referenceSize,
            danglingReferences: dangling, reachableCount: facts.reachableCount, reachableBytes: facts.reachableBytes,
            weaklyReachableCount: facts.weaklyReachableCount, weaklyReachableBytes: facts.weaklyReachableBytes,
            unreachableCount: facts.unreachableCount, unreachableBytes: facts.unreachableBytes,
            buildSeconds: Date().timeIntervalSince(started), createdAt: Date()
        )
        try JSONEncoder().encode(meta).write(to: directory.appendingPathComponent(Files.meta), options: .atomic)
        try Data().write(to: directory.appendingPathComponent(Files.complete))
        succeeded = true
        progress(Progress(phase: .dominators, fraction: 1))
        return try HeapIndex.open(directory: directory, dump: url)
    }

    enum Files {
        static let ids = "ids.u64"
        static let offsets = "offsets.i64"
        static let classes = "class.i32"
        static let kinds = "kind.u8"
        static let lengths = "length.u32"
        static let lookup = "lookup.u32"
        static let outOffsets = "out-offsets.u32"
        static let outTargets = "out-targets.u32"
        static let inOffsets = "in-offsets.u32"
        static let inSources = "in-sources.u32"
        static let memberOffsets = "member-offsets.u32"
        static let members = "members.i32"
        static let classTable = "classes.bin"
        static let roots = "roots.bin"
        static let meta = "meta.json"
        static let complete = "complete"
    }

    /// The high bit of a stored reference marks it weak (`Reference.referent`); numbers stay below 2^31.
    static let weakBit: UInt32 = 0x8000_0000

    // MARK: - Parallel helper

    /// Runs `body` for 0..<count with at most `limit` at once, results in index order.
    static func parallel<T: Sendable>(
        _ count: Int, _ limit: Int, _ body: @escaping @Sendable (Int) throws -> T
    ) async throws -> [T] {
        var results = [T?](repeating: nil, count: count)
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var next = 0
            func add() {
                guard next < count else { return }
                let index = next
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try body(index))
                }
            }
            for _ in 0..<max(1, limit) { add() }
            while let (index, value) = try await group.next() {
                results[index] = value
                add()
            }
        }
        return results.map { $0! }
    }

    static func walk<V: HprofHeapVisitor>(_ item: HeapDumpCensus.WorkItem, fd: Int32, idSize: Int, visitor: inout V) throws {
        guard let first = item.segments.first, let last = item.segments.last else { return }
        let reader = HprofByteReader(fd: fd, start: first.lowerBound, end: last.upperBound)
        for segment in item.segments {
            try Task.checkCancellation()
            do {
                try HprofHeapWalker.walk(segment, reader: reader, idSize: idSize, visitor: &visitor)
            } catch is HprofError {
                // The census reports a damaged segment; the index keeps what was read before it.
            }
        }
    }

    // MARK: - Pass 1

    struct CollectorPart: Sendable {
        struct Root: Sendable {
            let kind: HprofRootKind
            let id: UInt64
            let first: UInt32
            let second: UInt32
        }

        var objects = 0
        var referenceSlots = 0
        var classes: [HprofClassDumpRecord] = []
        var classOffsets: [Int64] = []
        var roots: [Root] = []
    }

    struct CollectorVisitor: HprofHeapVisitor {
        var part = CollectorPart()
        var wantsContents: Bool { false }

        mutating func instance(id: UInt64, classID: UInt64, offset: Int64, fieldBytes: Int, fields: UnsafeRawPointer?) {
            part.objects += 1
            part.referenceSlots += fieldBytes / 4
        }

        mutating func objectArray(id: UInt64, classID: UInt64, length: Int, offset: Int64, elements: UnsafeRawPointer?) {
            part.objects += 1
            part.referenceSlots += length
        }

        mutating func primitiveArray(id: UInt64, type: HprofBasicType, length: Int, offset: Int64) {
            part.objects += 1
        }

        mutating func classDump(_ record: HprofClassDumpRecord, offset: Int64) {
            part.objects += 1
            part.referenceSlots += record.statics.count + 2
            part.classes.append(record)
            part.classOffsets.append(offset)
        }

        mutating func root(_ kind: HprofRootKind, id: UInt64, first: UInt32, second: UInt32) {
            part.roots.append(.init(kind: kind, id: id, first: first, second: second))
        }
    }

    // MARK: - Pass 2

    struct ObjectRecord {
        var id: UInt64
        var offset: Int64
        var classIndex: Int32
        var length: UInt32
        var kind: UInt8
    }

    struct RecordVisitor: HprofHeapVisitor {
        let records: HeapMappedArray<ObjectRecord>
        var next: Int
        let classIndexByID: [UInt64: Int32]
        let primitiveIndex: [Int32]
        var wantsContents: Bool { false }

        @inline(__always)
        mutating func put(_ record: ObjectRecord) {
            // A chunk read twice must not run past its share (a segment changed underneath).
            guard next < records.count else { return }
            records[next] = record
            next += 1
        }

        mutating func instance(id: UInt64, classID: UInt64, offset: Int64, fieldBytes: Int, fields: UnsafeRawPointer?) {
            put(ObjectRecord(id: id, offset: offset, classIndex: classIndexByID[classID] ?? 0,
                             length: UInt32(clamping: fieldBytes), kind: HeapObjectKind.instance.rawValue))
        }

        mutating func objectArray(id: UInt64, classID: UInt64, length: Int, offset: Int64, elements: UnsafeRawPointer?) {
            put(ObjectRecord(id: id, offset: offset, classIndex: classIndexByID[classID] ?? 0,
                             length: UInt32(clamping: length), kind: HeapObjectKind.objectArray.rawValue))
        }

        mutating func primitiveArray(id: UInt64, type: HprofBasicType, length: Int, offset: Int64) {
            put(ObjectRecord(id: id, offset: offset, classIndex: primitiveIndex[Int(type.rawValue)],
                             length: UInt32(clamping: length), kind: HeapObjectKind.primitiveArray.rawValue))
        }

        mutating func classDump(_ record: HprofClassDumpRecord, offset: Int64) {
            put(ObjectRecord(id: record.id, offset: offset, classIndex: classIndexByID[record.id] ?? 0,
                             length: 0, kind: HeapObjectKind.classObject.rawValue))
        }

        mutating func root(_ kind: HprofRootKind, id: UInt64, first: UInt32, second: UInt32) {}
    }

    static func isSorted(_ slice: UnsafeMutableBufferPointer<ObjectRecord>) -> Bool {
        guard slice.count > 1 else { return true }
        for index in 1..<slice.count where slice[index].id < slice[index - 1].id { return false }
        return true
    }

    /// K-way merge of sorted runs. A run keeps the pen while its next id is no larger than every
    /// other run's head, which is nearly always for a dump written in address order.
    static func merge(
        _ records: HeapMappedArray<ObjectRecord>, runs: [Range<Int>],
        ids: HeapMappedArray<UInt64>, offsets: HeapMappedArray<Int64>, classes: HeapMappedArray<Int32>,
        kinds: HeapMappedArray<UInt8>, lengths: HeapMappedArray<UInt32>
    ) {
        var heads = runs.map(\.lowerBound)
        // A binary min-heap of run indexes keyed by their head id.
        var heap: [Int] = runs.indices.filter { !runs[$0].isEmpty }
        func key(_ run: Int) -> UInt64 { records[heads[run]].id }
        func siftDown(_ start: Int) {
            var parent = start
            while true {
                let left = 2 * parent + 1
                guard left < heap.count else { return }
                var child = left
                if left + 1 < heap.count, key(heap[left + 1]) < key(heap[left]) { child = left + 1 }
                guard key(heap[child]) < key(heap[parent]) else { return }
                heap.swapAt(child, parent)
                parent = child
            }
        }
        for index in stride(from: heap.count / 2 - 1, through: 0, by: -1) { siftDown(index) }
        var number = 1
        while let top = heap.first {
            let limit = runs[top].upperBound
            let second: UInt64 = heap.count > 1
                ? min(key(heap[1]), heap.count > 2 ? key(heap[2]) : UInt64.max)
                : UInt64.max
            repeat {
                let record = records[heads[top]]
                ids[number] = record.id
                offsets[number] = record.offset
                classes[number] = record.classIndex
                kinds[number] = record.kind
                lengths[number] = record.length
                number += 1
                heads[top] += 1
            } while heads[top] < limit && records[heads[top]].id <= second
            if heads[top] >= limit {
                heap.swapAt(0, heap.count - 1)
                heap.removeLast()
            }
            siftDown(0)
        }
    }

    // MARK: - Pass 3

    struct EdgePart: Sendable {
        let file: URL
        let count: Int
        let dangling: Int
    }

    static func numberRanges(total: Int, parts: Int) -> [Range<Int>] {
        let size = max(1, (total + parts - 1) / parts)
        return stride(from: 1, to: total, by: size).map { $0..<min(total, $0 + size) }
    }

    /// The references of objects `range`, written in order to `temp`; each object's count goes to
    /// `degrees[n + 1]`.
    static func followReferences(
        _ range: Range<Int>, fd: Int32, fileSize: Int64, idSize I: Int, lookup: HeapIDLookup,
        offsets: HeapMappedArray<Int64>, classes: HeapMappedArray<Int32>, kinds: HeapMappedArray<UInt8>,
        lengths: HeapMappedArray<UInt32>, layouts: [ClassTable.ReferenceLayout], classTable: ClassTable,
        degrees: HeapMappedArray<UInt32>, temp: URL
    ) throws -> EdgePart {
        let out = try EdgeFileWriter(url: temp)
        let reader = HprofByteReader(fd: fd, start: 0, end: fileSize)
        var dangling = 0
        @inline(__always) func emit(_ id: UInt64, weak: Bool, count: inout UInt32) {
            guard id != 0 else { return }
            guard let target = lookup.number(of: id) else {
                dangling += 1
                return
            }
            out.append(UInt32(target) | (weak ? weakBit : 0))
            count += 1
        }
        let headerBytes = 2 * I + 9
        for n in range {
            if (n - range.lowerBound) & 0xFFFF == 0 { try Task.checkCancellation() }
            var count: UInt32 = 0
            let offset = offsets[n]
            switch HeapObjectKind(rawValue: kinds[n]) {
            case .instance:
                let classIndex = Int(classes[n])
                let length = Int(lengths[n])
                guard classIndex > 0, classIndex < layouts.count, length > 0 else { break }
                let layout = layouts[classIndex]
                guard !layout.slots.isEmpty, layout.fieldBytes == length else { break }
                reader.seek(to: offset + Int64(headerBytes))
                let p = try reader.peek(length)
                for slot in layout.slots {
                    emit(HprofByteReader.id(p, Int(slot.offset), size: I), weak: slot.isWeak, count: &count)
                }
            case .objectArray:
                var remaining = Int(lengths[n])
                var position = offset + Int64(headerBytes)
                while remaining > 0 {
                    let chunk = min(remaining, 1 << 16)
                    reader.seek(to: position)
                    let p = try reader.peek(chunk * I)
                    for index in 0..<chunk {
                        emit(HprofByteReader.id(p, index * I, size: I), weak: false, count: &count)
                    }
                    remaining -= chunk
                    position += Int64(chunk * I)
                }
            case .classObject:
                let classIndex = Int(classes[n])
                guard classIndex > 0, classIndex < classTable.entries.count else { break }
                let entry = classTable.entries[classIndex]
                emit(entry.superID, weak: false, count: &count)
                emit(entry.loaderID, weak: false, count: &count)
                for field in entry.statics where field.type == .object {
                    emit(field.value, weak: false, count: &count)
                }
            case .primitiveArray, .superRoot, .none:
                break
            }
            degrees[n + 1] = count
        }
        try out.close()
        return EdgePart(file: temp, count: out.count, dangling: dangling)
    }

    static func copy(_ file: URL, count: Int, into array: HeapMappedArray<UInt32>, at start: Int) throws {
        let fd = Darwin.open(file.path, O_RDONLY)
        guard fd >= 0 else { throw HeapIndexError.io("read \(file.lastPathComponent)", errno) }
        defer { Darwin.close(fd) }
        let bytes = count * 4
        var done = 0
        let destination = UnsafeMutableRawPointer(array.base + start)
        while done < bytes {
            let result = pread(fd, destination + done, bytes - done, off_t(done))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw HeapIndexError.io("read \(file.lastPathComponent)", errno) }
            done += result
        }
    }

    // MARK: - Referrers and groups

    static func transpose(
        outOffsets: HeapMappedArray<UInt32>, outTargets: HeapMappedArray<UInt32>, total: Int,
        inOffsets: HeapMappedArray<UInt32>, inSources: HeapMappedArray<UInt32>, directory: URL
    ) throws {
        let edges = outTargets.count
        for e in 0..<edges {
            inOffsets[Int(outTargets[e] & ~weakBit) + 1] &+= 1
        }
        for n in 0..<total { inOffsets[n + 1] &+= inOffsets[n] }
        // The cursor of each target, where its next referrer goes: a mapped file, not 400 MB of heap.
        let cursorURL = directory.appendingPathComponent("cursor.tmp")
        let cursor = try HeapMappedArray<UInt32>.create(cursorURL, count: total)
        defer { try? FileManager.default.removeItem(at: cursorURL) }
        memcpy(UnsafeMutableRawPointer(cursor.base), UnsafeRawPointer(inOffsets.base), total * 4)
        for n in 0..<total {
            let start = Int(outOffsets[n])
            let end = Int(outOffsets[n + 1])
            guard start < end else { continue }
            for e in start..<end {
                let stored = outTargets[e]
                let target = Int(stored & ~weakBit)
                inSources[Int(cursor[target])] = UInt32(n) | (stored & weakBit)
                cursor[target] += 1
            }
        }
    }

    static func groupMembers(
        total: Int, classes: HeapMappedArray<Int32>, kinds: HeapMappedArray<UInt8>, mirrorGroup: Int32,
        memberOffsets: HeapMappedArray<UInt32>, members: HeapMappedArray<Int32>, groupCount: Int
    ) {
        @inline(__always) func group(_ n: Int) -> Int {
            kinds[n] == HeapObjectKind.classObject.rawValue ? Int(mirrorGroup) : Int(classes[n])
        }
        for n in 1..<total {
            let g = group(n)
            if g >= 0, g < groupCount { memberOffsets[g + 1] += 1 }
        }
        for g in 0..<groupCount { memberOffsets[g + 1] += memberOffsets[g] }
        var cursor = (0..<groupCount).map { memberOffsets[$0] }
        for n in 1..<total {
            let g = group(n)
            guard g >= 0, g < groupCount else { continue }
            members[Int(cursor[g])] = Int32(n)
            cursor[g] += 1
        }
    }

    static func writeRoots(_ roots: [CollectorPart.Root], lookup: HeapIDLookup, to url: URL) throws {
        var writer = HeapBinaryWriter()
        writer.u32(UInt32(roots.count))
        for root in roots {
            writer.u8(HprofRootKind.allCases.firstIndex(of: root.kind).map(UInt8.init) ?? 0)
            writer.u64(root.id)
            writer.u32(UInt32(bitPattern: lookup.number(of: root.id) ?? -1))
            writer.u32(root.first)
            writer.u32(root.second)
        }
        try writer.data.write(to: url, options: .atomic)
    }
}

/// Lets the builder flush arrays of different element types.
protocol HeapFlushable {
    func flushToDisk() throws
}

extension HeapMappedArray: HeapFlushable {
    func flushToDisk() throws { try flush() }
}

/// Appends `UInt32`s to a file through a buffer.
final class EdgeFileWriter {
    private let fd: Int32
    private var buffer: [UInt32] = []
    private(set) var count = 0

    init(url: URL) throws {
        fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw HeapIndexError.io("create \(url.lastPathComponent)", errno) }
        buffer.reserveCapacity(1 << 18)
    }

    @inline(__always)
    func append(_ value: UInt32) {
        buffer.append(value)
        count += 1
        if buffer.count == 1 << 18 { try? drain() }
    }

    private func drain() throws {
        guard !buffer.isEmpty else { return }
        try buffer.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let result = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw HeapIndexError.io("write edges", errno) }
                done += result
            }
        }
        buffer.removeAll(keepingCapacity: true)
    }

    func close() throws {
        defer { Darwin.close(fd) }
        try drain()
    }
}
