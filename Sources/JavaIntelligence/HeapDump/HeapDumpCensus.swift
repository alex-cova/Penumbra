import Darwin
import Foundation

/// What a heap dump is made of, by class, without an object index: phase 1 of
/// `docs/HEAP_DUMP_PLAN.md` (passes 1 and 2). One sequential walk of the top-level records
/// (strings, class names, where the heap segments are), then the heap segments in parallel, each
/// worker tallying its own share. Memory is bounded by the number of classes and strings, never by
/// the number of objects.
public enum HeapDumpCensus {
    public struct Progress: Sendable, Equatable {
        public enum Phase: String, Sendable {
            case scanningRecords = "Reading records"
            case countingObjects = "Counting objects"
            case summarizing = "Summarizing"
        }

        public let phase: Phase
        /// 0...1 over the whole read.
        public let fraction: Double
        public let bytesDone: Int64
        public let bytesTotal: Int64

        public init(phase: Phase, fraction: Double, bytesDone: Int64, bytesTotal: Int64) {
            self.phase = phase
            self.fraction = fraction
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
        }
    }

    public static func read(
        _ url: URL,
        maxConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> HeapDumpOverview {
        try await read(url, maxConcurrency: maxConcurrency, workItemBytes: 64 << 20, progress: progress)
    }

    /// `workItemBytes` is how much of the heap one worker takes at a time (tests make it small).
    static func read(
        _ url: URL, maxConcurrency: Int, workItemBytes: Int64,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> HeapDumpOverview {
        let started = Date()
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw HprofError.cannotOpen(String(cString: strerror(errno))) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw HprofError.cannotOpen(String(cString: strerror(errno))) }
        let fileSize = Int64(info.st_size)

        var headBytes = [UInt8](repeating: 0, count: 64)
        let headCount = headBytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 64, 0) }
        let header = try HprofHeader.parse(Data(headBytes.prefix(max(headCount, 0))))
        let idSize = header.idSize

        // Pass 1: top-level records.
        progress(Progress(phase: .scanningRecords, fraction: 0, bytesDone: 0, bytesTotal: fileSize))
        let topLevel = try scanTopLevel(fd: fd, fileSize: fileSize, header: header)
        try Task.checkCancellation()
        let scanShare = 0.03
        progress(Progress(phase: .countingObjects, fraction: scanShare, bytesDone: 0, bytesTotal: fileSize))

        // Pass 2: heap segments, in groups of about `workItemBytes` so the workers stay balanced.
        let items = workItems(topLevel.segments, target: workItemBytes)
        let segmentBytes = topLevel.segments.reduce(Int64(0)) { $0 + Int64($1.count) }
        let counter = ByteCounter()
        var parts: [CensusPart] = []
        try await withThrowingTaskGroup(of: CensusPart.self) { group in
            var next = 0
            func addNext() {
                guard next < items.count else { return }
                let item = items[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let part = walk(item, fd: fd, idSize: idSize)
                    let done = counter.add(part.bytes)
                    let fraction = scanShare + (1 - scanShare - 0.02) * Double(done) / Double(max(segmentBytes, 1))
                    progress(Progress(phase: .countingObjects, fraction: fraction, bytesDone: done, bytesTotal: segmentBytes))
                    return part
                }
            }
            for _ in 0..<max(1, maxConcurrency) { addNext() }
            while let part = try await group.next() {
                parts.append(part)
                addNext()
            }
        }
        try Task.checkCancellation()
        progress(Progress(phase: .summarizing, fraction: 0.98, bytesDone: segmentBytes, bytesTotal: segmentBytes))

        var merged = CensusPart()
        for part in parts { merged.merge(part) }
        let names = try readClassNames(fd: fd, fileSize: fileSize, topLevel: topLevel)
        return HeapDumpOverview.make(
            url: url, fileSize: fileSize, header: header, topLevel: topLevel, census: merged,
            classNames: names, elapsed: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Pass 1

    struct TopLevel: Sendable {
        /// UTF8 record id → where its bytes are.
        var strings: [UInt64: (offset: Int64, length: Int32)] = [:]
        /// Class object id → name string id (LOAD_CLASS).
        var classNameIDs: [UInt64: UInt64] = [:]
        var segments: [Range<Int64>] = []
        var stackTraceCount = 0
        var stackFrameCount = 0
        /// LOAD_CLASS serial → class object id (stack frames name their class by serial).
        var classSerials: [UInt32: UInt64] = [:]
        /// STACK_FRAME by frame id.
        var frames: [UInt64: StackFrame] = [:]
        /// STACK_TRACE by serial.
        var traces: [UInt32: StackTrace] = [:]
        var truncatedAt: Int64?
    }

    struct StackFrame: Sendable {
        let methodNameID: UInt64
        let signatureID: UInt64
        let sourceFileID: UInt64
        let classSerial: UInt32
        /// > 0 a line; -1 unknown, -2 compiled, -3 native.
        let line: Int32
    }

    struct StackTrace: Sendable {
        let threadSerial: UInt32
        let frameIDs: [UInt64]
    }

    static func scanTopLevel(fd: Int32, fileSize: Int64, header: HprofHeader) throws -> TopLevel {
        let idSize = header.idSize
        let reader = HprofByteReader(fd: fd, start: Int64(header.length), end: fileSize)
        var result = TopLevel()
        while !reader.isAtEnd {
            guard reader.remaining >= 9 else {
                result.truncatedAt = reader.position
                break
            }
            let recordStart = reader.position
            let p = try reader.take(9)
            let tag = p.load(as: UInt8.self)
            let length = Int64(HprofByteReader.u4(p, 5))
            let bodyStart = reader.position
            var bodyEnd = bodyStart + length
            let isCut = bodyEnd > fileSize
            if isCut {
                result.truncatedAt = recordStart
                bodyEnd = fileSize
            }
            switch HprofFormat.Tag(rawValue: tag) {
            case .utf8 where length >= idSize:
                let id = HprofByteReader.id(try reader.take(idSize), 0, size: idSize)
                result.strings[id] = (reader.position, Int32(clamping: bodyEnd - reader.position))
            case .loadClass where length >= 8 + 2 * Int64(idSize):
                let q = try reader.take(8 + 2 * idSize)
                let classID = HprofByteReader.id(q, 4, size: idSize)
                result.classNameIDs[classID] = HprofByteReader.id(q, 8 + idSize, size: idSize)
                result.classSerials[HprofByteReader.u4(q, 0)] = classID
            case .heapDump, .heapDumpSegment:
                if bodyEnd > bodyStart { result.segments.append(bodyStart..<bodyEnd) }
            case .stackTrace where length >= 12:
                result.stackTraceCount += 1
                let q = try reader.take(12)
                let serial = HprofByteReader.u4(q, 0)
                let thread = HprofByteReader.u4(q, 4)
                let count = Int(min(Int64(HprofByteReader.u4(q, 8)), (length - 12) / Int64(idSize)))
                var ids: [UInt64] = []
                ids.reserveCapacity(count)
                if count > 0 {
                    let f = try reader.take(count * idSize)
                    for index in 0..<count { ids.append(HprofByteReader.id(f, index * idSize, size: idSize)) }
                }
                result.traces[serial] = StackTrace(threadSerial: thread, frameIDs: ids)
            case .stackFrame where length >= 4 * Int64(idSize) + 8:
                result.stackFrameCount += 1
                let q = try reader.take(4 * idSize + 8)
                result.frames[HprofByteReader.id(q, 0, size: idSize)] = StackFrame(
                    methodNameID: HprofByteReader.id(q, idSize, size: idSize),
                    signatureID: HprofByteReader.id(q, 2 * idSize, size: idSize),
                    sourceFileID: HprofByteReader.id(q, 3 * idSize, size: idSize),
                    classSerial: HprofByteReader.u4(q, 4 * idSize),
                    line: Int32(bitPattern: HprofByteReader.u4(q, 4 * idSize + 4))
                )
            default:
                break
            }
            if isCut { break }
            reader.seek(to: bodyEnd)
        }
        return result
    }

    /// Class names (Java form), by class object id.
    static func readClassNames(fd: Int32, fileSize: Int64, topLevel: TopLevel) throws -> [UInt64: String] {
        let raw = try readStrings(fd: fd, fileSize: fileSize, ids: Set(topLevel.classNameIDs.values), topLevel: topLevel)
        var names: [UInt64: String] = [:]
        names.reserveCapacity(topLevel.classNameIDs.count)
        for (classID, nameID) in topLevel.classNameIDs {
            if let name = raw[nameID] { names[classID] = HprofClassName.javaName(name) }
        }
        return names
    }

    /// UTF8 records by id, read in file order so the reader moves forward through its buffer.
    static func readStrings(fd: Int32, fileSize: Int64, ids: Set<UInt64>, topLevel: TopLevel) throws -> [UInt64: String] {
        let wanted = ids.compactMap { id -> (UInt64, Int64, Int32)? in
            guard let location = topLevel.strings[id] else { return nil }
            return (id, location.offset, location.length)
        }.sorted { $0.1 < $1.1 }
        let reader = HprofByteReader(fd: fd, start: 0, end: fileSize, capacity: 1 << 20)
        var strings: [UInt64: String] = [:]
        strings.reserveCapacity(wanted.count)
        for (id, offset, length) in wanted {
            reader.seek(to: offset)
            let bytes = try reader.take(Int(length))
            strings[id] = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(length)), as: UTF8.self)
        }
        return strings
    }

    // MARK: - Pass 2

    struct WorkItem: Sendable {
        let segments: [Range<Int64>]
    }

    static func workItems(_ segments: [Range<Int64>], target: Int64) -> [WorkItem] {
        var items: [WorkItem] = []
        var current: [Range<Int64>] = []
        var size: Int64 = 0
        for segment in segments {
            current.append(segment)
            size += Int64(segment.count)
            if size >= target {
                items.append(WorkItem(segments: current))
                current = []
                size = 0
            }
        }
        if !current.isEmpty { items.append(WorkItem(segments: current)) }
        return items
    }

    struct InstanceTally: Sendable {
        var count = 0
        var fieldBytes = 0

        @inline(__always) mutating func add(_ bytes: Int) {
            count += 1
            fieldBytes += bytes
        }
    }

    struct ArrayTally: Sendable {
        var count = 0
        var elements = 0

        @inline(__always) mutating func add(_ length: Int) {
            count += 1
            elements += length
        }
    }

    struct ClassInfo: Sendable {
        let id: UInt64
        let superID: UInt64
        let loaderID: UInt64
        let declaredPrimitiveBytes: Int
        let declaredReferences: Int
        let staticPrimitiveBytes: Int
        let staticReferences: Int
    }

    /// One worker's tallies. Arrays keep their element count per object so a size can be computed
    /// under any layout: `arraySizes[i]` is the total under `HeapObjectLayout.candidates[i]`.
    struct CensusPart: Sendable {
        var instances: [UInt64: InstanceTally] = [:]
        var objectArrays: [UInt64: ArrayTally] = [:]
        var objectArraySizes: [UInt64: SIMD8<Int64>] = [:]
        var primitiveArrays: [UInt8: ArrayTally] = [:]
        var primitiveArraySizes: [UInt8: SIMD8<Int64>] = [:]
        var classes: [ClassInfo] = []
        var roots: [HprofRootKind: Int] = [:]
        var samples: [HeapGapSample] = []
        var problems: [String] = []
        var bytes: Int64 = 0

        mutating func merge(_ other: CensusPart) {
            instances.merge(other.instances) { InstanceTally(count: $0.count + $1.count, fieldBytes: $0.fieldBytes + $1.fieldBytes) }
            objectArrays.merge(other.objectArrays) { ArrayTally(count: $0.count + $1.count, elements: $0.elements + $1.elements) }
            objectArraySizes.merge(other.objectArraySizes, uniquingKeysWith: &+)
            primitiveArrays.merge(other.primitiveArrays) { ArrayTally(count: $0.count + $1.count, elements: $0.elements + $1.elements) }
            primitiveArraySizes.merge(other.primitiveArraySizes, uniquingKeysWith: &+)
            classes.append(contentsOf: other.classes)
            roots.merge(other.roots, uniquingKeysWith: +)
            samples.append(contentsOf: other.samples)
            if problems.count < 20 { problems.append(contentsOf: other.problems.prefix(20 - problems.count)) }
            bytes += other.bytes
        }
    }

    static let maxSamplesPerPart = 8192

    /// Sizes of one array under every candidate layout (64-bit) or the 32-bit one.
    @inline(__always)
    static func arraySizes(length: Int, elementSize: Int?, idSize: Int) -> SIMD8<Int64> {
        var sizes = SIMD8<Int64>()
        if idSize == 4 {
            sizes[0] = Int64(HeapObjectLayout.thirtyTwoBit.arraySize(length: length, elementSize: elementSize ?? 4))
            return sizes
        }
        for (index, layout) in HeapObjectLayout.candidates.enumerated() {
            sizes[index] = Int64(layout.arraySize(length: length, elementSize: elementSize ?? layout.referenceSize))
        }
        return sizes
    }

    static func walk(_ item: WorkItem, fd: Int32, idSize: Int) -> CensusPart {
        var visitor = CensusVisitor(idSize: idSize)
        guard let first = item.segments.first, let last = item.segments.last else { return visitor.part }
        let reader = HprofByteReader(fd: fd, start: first.lowerBound, end: last.upperBound)
        for segment in item.segments {
            visitor.previous = nil
            do {
                try HprofHeapWalker.walk(segment, reader: reader, idSize: idSize, visitor: &visitor)
            } catch let error as HprofError {
                visitor.part.problems.append(error.description)
            } catch {
                visitor.part.problems.append(error.localizedDescription)
            }
            visitor.part.bytes += Int64(segment.count)
        }
        return visitor.part
    }

    /// Tallies by class, and samples the spacing of neighbours for the layout detection.
    struct CensusVisitor: HprofHeapVisitor {
        let idSize: Int
        var part = CensusPart()
        var previous: (id: UInt64, shape: HeapGapSample.Shape)?
        var pairs = 0

        var wantsContents: Bool { false }

        @inline(__always)
        mutating func sample(_ id: UInt64, _ shape: HeapGapSample.Shape) {
            defer { previous = (id, shape) }
            guard let prior = previous, id > prior.id else { return }
            let gap = id - prior.id
            guard gap <= 1 << 20 else { return }
            pairs += 1
            guard part.samples.count < maxSamplesPerPart, part.samples.count < 2048 || pairs % 16 == 0 else { return }
            part.samples.append(HeapGapSample(gap: Int(gap), shape: prior.shape))
        }

        mutating func instance(id: UInt64, classID: UInt64, offset: Int64, fieldBytes: Int, fields: UnsafeRawPointer?) {
            part.instances[classID, default: InstanceTally()].add(fieldBytes)
            sample(id, .instance(classID: classID))
        }

        mutating func objectArray(id: UInt64, classID: UInt64, length: Int, offset: Int64, elements: UnsafeRawPointer?) {
            part.objectArrays[classID, default: ArrayTally()].add(length)
            part.objectArraySizes[classID, default: SIMD8<Int64>()] &+= arraySizes(length: length, elementSize: nil, idSize: idSize)
            sample(id, .objectArray(length: length))
        }

        mutating func primitiveArray(id: UInt64, type: HprofBasicType, length: Int, offset: Int64) {
            let elementSize = type.size(idSize: idSize)
            part.primitiveArrays[type.rawValue, default: ArrayTally()].add(length)
            part.primitiveArraySizes[type.rawValue, default: SIMD8<Int64>()] &+= arraySizes(length: length, elementSize: elementSize, idSize: idSize)
            sample(id, .primitiveArray(elementSize: elementSize, length: length))
        }

        mutating func classDump(_ record: HprofClassDumpRecord, offset: Int64) {
            part.classes.append(ClassInfo(
                id: record.id, superID: record.superID, loaderID: record.loaderID,
                declaredPrimitiveBytes: record.declaredPrimitiveBytes, declaredReferences: record.declaredReferences,
                staticPrimitiveBytes: record.staticPrimitiveBytes, staticReferences: record.staticReferences
            ))
            previous = nil
        }

        mutating func root(_ kind: HprofRootKind, id: UInt64, first: UInt32, second: UInt32) {
            part.roots[kind, default: 0] += 1
        }
    }

    static func rootBodySize(_ kind: HprofRootKind, idSize I: Int) -> Int {
        switch kind {
        case .unknown, .stickyClass, .monitorUsed: return I
        case .jniGlobal: return 2 * I
        case .jniLocal, .javaFrame, .threadObject: return I + 8
        case .nativeStack, .threadBlock: return I + 4
        }
    }

    final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var total: Int64 = 0

        func add(_ bytes: Int64) -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            total += bytes
            return total
        }
    }
}
