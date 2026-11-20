import Foundation
@testable import JavaIntelligence
import XCTest

final class HprofHeaderTests: XCTestCase {
    func testParsesVersionIDSizeAndTime() throws {
        let header = try HprofHeader.parse(HprofTestWriter().data())
        XCTAssertEqual(header.version, "JAVA PROFILE 1.0.2")
        XCTAssertEqual(header.idSize, 8)
        XCTAssertEqual(header.timestamp.timeIntervalSince1970, 1_763_000_000, accuracy: 0.001)
        XCTAssertEqual(header.length, "JAVA PROFILE 1.0.2".utf8.count + 1 + 12)
        XCTAssertEqual(try HprofHeader.parse(HprofTestWriter(idSize: 4, version: "JAVA PROFILE 1.0.1").data()).idSize, 4)
    }

    func testRefusesWhatItCannotRead() {
        XCTAssertThrowsError(try HprofHeader.parse(Data("hello world\0".utf8))) {
            XCTAssertEqual($0 as? HprofError, .notAHeapDump)
        }
        XCTAssertThrowsError(try HprofHeader.parse(HprofTestWriter(version: "JAVA PROFILE 1.0.3").data())) {
            XCTAssertEqual($0 as? HprofError, .unsupportedVersion("JAVA PROFILE 1.0.3"))
            XCTAssertTrue(String(describing: $0).contains("hprof-conv"))
        }
        XCTAssertThrowsError(try HprofHeader.parse(Data([0x1F, 0x8B, 0x08, 0x00]))) {
            XCTAssertEqual($0 as? HprofError, .compressed)
        }
        XCTAssertThrowsError(try HprofHeader.parse(HprofTestWriter(idSize: 2).data())) {
            XCTAssertEqual($0 as? HprofError, .badIDSize(2))
        }
    }

    func testDetectorReadsBytesNotNames() throws {
        XCTAssertTrue(HprofDetector.isHeapDump(head: HprofTestWriter().data()))
        XCTAssertTrue(HprofDetector.isHeapDump(head: HprofTestWriter(version: "JAVA PROFILE 1.0.3").data()))
        XCTAssertFalse(HprofDetector.isHeapDump(head: Data("JAVA PROFILE notes about profiling\n".utf8)))
        XCTAssertFalse(HprofDetector.isHeapDump(head: Data()))
        XCTAssertTrue(HprofDetector.hasHeapDumpExtension(URL(fileURLWithPath: "/tmp/x.HPROF")))
        XCTAssertTrue(HprofDetector.hasHeapDumpExtension(URL(fileURLWithPath: "/tmp/x.hprof.gz")))
    }

    func testClassNamesBecomeJavaNames() {
        XCTAssertEqual(HprofClassName.javaName("java/lang/String"), "java.lang.String")
        XCTAssertEqual(HprofClassName.javaName("[Ljava/lang/String;"), "java.lang.String[]")
        XCTAssertEqual(HprofClassName.javaName("[[I"), "int[][]")
        XCTAssertEqual(HprofClassName.javaName("a/b/Outer$Inner"), "a.b.Outer$Inner")
        XCTAssertEqual(HprofClassName.javaName("java.lang.Object"), "java.lang.Object")
    }
}

final class HeapObjectLayoutTests: XCTestCase {
    func testSizesFollowHeaderReferencesAndAlignment() {
        // int + reference.
        XCTAssertEqual(HeapObjectLayout.compressed.instanceSize(primitiveBytes: 4, references: 1), 24)
        XCTAssertEqual(HeapObjectLayout.uncompressed.instanceSize(primitiveBytes: 4, references: 1), 32)
        XCTAssertEqual(HeapObjectLayout.compactHeaders.instanceSize(primitiveBytes: 4, references: 1), 16)
        // An empty object is its header, aligned.
        XCTAssertEqual(HeapObjectLayout.compressed.instanceSize(primitiveBytes: 0, references: 0), 16)
        XCTAssertEqual(HeapObjectLayout.compactHeaders.instanceSize(primitiveBytes: 0, references: 0), 8)
        // byte[10]: 12 + 4 + 10 = 26 → 32. long[1] under compact headers: base 12 → 16, + 8 = 24.
        XCTAssertEqual(HeapObjectLayout.compressed.arraySize(length: 10, elementSize: 1), 32)
        XCTAssertEqual(HeapObjectLayout.compactHeaders.arraySize(length: 1, elementSize: 8), 24)
        XCTAssertEqual(HeapObjectLayout.uncompressed.arraySize(length: 0, elementSize: 8), 24)
    }
}

final class HeapDumpCensusTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeapDumpCensusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func read(
        _ writer: HprofTestWriter, concurrency: Int = 4, workItemBytes: Int64 = 64 << 20
    ) async throws -> HeapDumpOverview {
        let url = directory.appendingPathComponent("\(UUID().uuidString).hprof")
        try writer.write(to: url)
        return try await HeapDumpCensus.read(url, maxConcurrency: concurrency, workItemBytes: workItemBytes) { _ in }
    }

    // Class ids.
    private let object: UInt64 = 0x100
    private let string: UInt64 = 0x110
    private let base: UInt64 = 0x120
    private let derived: UInt64 = 0x130
    private let stringArray: UInt64 = 0x140
    private let classClass: UInt64 = 0x150

    /// java.lang.Object; String (int hash, byte coder, ref value); Base (long); Derived extends
    /// Base (ref); String[]; java.lang.Class (two refs).
    private func classes(_ writer: inout HprofTestWriter) {
        writer.loadClass(object, name: "java/lang/Object")
        writer.loadClass(string, name: "java/lang/String")
        writer.loadClass(base, name: "com/acme/Base")
        writer.loadClass(derived, name: "com/acme/Derived")
        writer.loadClass(stringArray, name: "[Ljava/lang/String;")
        writer.loadClass(classClass, name: "java/lang/Class")
        writer.segment { segment in
            segment.classDump(object)
            segment.classDump(string, superID: object, fields: [.int, .byte, .object])
            segment.classDump(base, superID: object, loaderID: 0x900, fields: [.long])
            segment.classDump(derived, superID: base, loaderID: 0x900, statics: [.object, .int], fields: [.object])
            segment.classDump(stringArray, superID: object)
            segment.classDump(classClass, superID: object, fields: [.object, .object], constants: [.int])
        }
    }

    func testCountsObjectsByClassWithInheritedFieldsAndRoots() async throws {
        var writer = HprofTestWriter()
        classes(&writer)
        writer.stackTrace()
        writer.segment { segment in
            // Not adjacent (no layout evidence): the fallback layout, compressed, applies.
            segment.instance(0x10_000, classID: string, fieldBytes: 13)
            segment.instance(0x20_000, classID: string, fieldBytes: 13)
            segment.instance(0x30_000, classID: derived, fieldBytes: 16)
            segment.objectArray(0x40_000, classID: stringArray, elements: [0x10_000, 0x20_000, 0])
            segment.primitiveArray(0x50_000, type: .byte, length: 10)
            segment.primitiveArray(0x60_000, type: .long, length: 3)
            segment.root(.threadObject, 0x70_000)
            segment.root(.javaFrame, 0x10_000)
            segment.root(.javaFrame, 0x20_000)
            segment.root(.stickyClass, string)
            segment.root(.jniGlobal, 0x30_000)
        }
        writer.heapDumpEnd()
        let overview = try await read(writer)

        XCTAssertEqual(overview.instanceCount, 3)
        XCTAssertEqual(overview.objectArrayCount, 1)
        XCTAssertEqual(overview.primitiveArrayCount, 2)
        XCTAssertEqual(overview.classCount, 6)
        XCTAssertEqual(overview.objectCount, 12)
        XCTAssertEqual(overview.classLoaderCount, 2)
        XCTAssertEqual(overview.rootCounts, [.threadObject: 1, .javaFrame: 2, .stickyClass: 1, .jniGlobal: 1])
        XCTAssertEqual(overview.threadCount, 1)
        XCTAssertEqual(overview.stackTraceCount, 1)
        XCTAssertNil(overview.truncatedAt)
        XCTAssertEqual(overview.problems, [])
        XCTAssertEqual(overview.layout, .compressed)
        XCTAssertNil(overview.layoutConfidence)

        let rows = Dictionary(uniqueKeysWithValues: overview.histogram.rows.map { ($0.name, $0) })
        // String: 12 + 4 + 1 + 4 = 21 → 24, twice.
        XCTAssertEqual(rows["java.lang.String"]?.count, 2)
        XCTAssertEqual(rows["java.lang.String"]?.shallowBytes, 48)
        // Derived: its own reference plus Base's long: 12 + 8 + 4 = 24.
        XCTAssertEqual(rows["com.acme.Derived"]?.shallowBytes, 24)
        XCTAssertEqual(rows["com.acme.Derived"]?.kind, .instance)
        // String[3]: 12 + 4 + 3 × 4 = 28 → 32.
        XCTAssertEqual(rows["java.lang.String[]"]?.shallowBytes, 32)
        XCTAssertEqual(rows["java.lang.String[]"]?.kind, .objectArray)
        XCTAssertEqual(rows["byte[]"]?.shallowBytes, 32)
        // long[3]: base 16, + 24 = 40.
        XCTAssertEqual(rows["long[]"]?.shallowBytes, 40)
        XCTAssertEqual(rows["long[]"]?.kind, .primitiveArray)
        // Six mirrors of Class (two refs: 12 + 8 = 20 → 24), Derived's adding a ref and an int: 12 + 8 + 4 + 4 = 28 → 32.
        XCTAssertEqual(rows["java.lang.Class"]?.count, 6)
        XCTAssertEqual(rows["java.lang.Class"]?.shallowBytes, 5 * 24 + 32)
        XCTAssertNil(rows["com.acme.Base"], "a class without instances has no row")
        XCTAssertEqual(overview.histogram.totalCount, 12)
        XCTAssertEqual(overview.histogram.rows.first?.name, "java.lang.Class")

        // The same aggregates under another layout: String is 16 + 4 + 1 + 8 = 29 → 32.
        let wide = Dictionary(uniqueKeysWithValues: overview.histogram(layout: .uncompressed).rows.map { ($0.name, $0) })
        XCTAssertEqual(wide["java.lang.String"]?.shallowBytes, 64)
    }

    /// Instances laid out back to back as `layout` sizes them: Foo (int, reference) and Bar
    /// (reference) alternate, which only one candidate predicts entirely.
    private func densePair(_ layout: HeapObjectLayout, count: Int = 200) -> HprofTestWriter {
        var writer = HprofTestWriter()
        let foo: UInt64 = 0x200
        let bar: UInt64 = 0x210
        writer.loadClass(object, name: "java/lang/Object")
        writer.loadClass(foo, name: "Foo")
        writer.loadClass(bar, name: "Bar")
        writer.segment { segment in
            segment.classDump(object)
            segment.classDump(foo, superID: object, fields: [.int, .object])
            segment.classDump(bar, superID: object, fields: [.object])
            var address: UInt64 = 0x7_0000_0000
            for index in 0..<count {
                let isFoo = index.isMultiple(of: 2)
                segment.instance(address, classID: isFoo ? foo : bar, fieldBytes: isFoo ? 12 : 8)
                let size = isFoo
                    ? layout.instanceSize(primitiveBytes: 4, references: 1)
                    : layout.instanceSize(primitiveBytes: 0, references: 1)
                address += UInt64(size)
            }
        }
        return writer
    }

    func testDetectsTheLayoutFromAddressGaps() async throws {
        for layout in [HeapObjectLayout.compressed, .uncompressed, .compactHeaders] {
            let overview = try await read(densePair(layout))
            XCTAssertEqual(overview.layout, layout, "\(layout)")
            XCTAssertEqual(overview.layoutConfidence ?? 0, 1, accuracy: 0.0001)
            XCTAssertEqual(overview.layoutSampleCount, 199)
        }
    }

    func testTooFewNeighboursKeepTheFallback() async throws {
        let overview = try await read(densePair(.uncompressed, count: 10))
        XCTAssertEqual(overview.layout, .compressed)
        XCTAssertNil(overview.layoutConfidence)
    }

    func testFourByteIDsUseTheThirtyTwoBitLayout() async throws {
        var writer = HprofTestWriter(idSize: 4, version: "JAVA PROFILE 1.0.1")
        writer.loadClass(object, name: "java/lang/Object")
        writer.loadClass(string, name: "java/lang/String")
        var body = HeapSegmentWriter(idSize: 4)
        body.classDump(object)
        body.classDump(string, superID: object, fields: [.int, .object])
        body.instance(0x1000, classID: string, fieldBytes: 8)
        body.primitiveArray(0x2000, type: .char, length: 3)
        writer.record(HprofFormat.Tag.heapDump.rawValue, body.bytes)
        let overview = try await read(writer)
        XCTAssertEqual(overview.layout, .thirtyTwoBit)
        XCTAssertEqual(overview.availableLayouts, [.thirtyTwoBit])
        let rows = Dictionary(uniqueKeysWithValues: overview.histogram.rows.map { ($0.name, $0) })
        // 8 + 4 + 4 = 16; char[3]: 8 + 4 + 6 = 18 → 24.
        XCTAssertEqual(rows["java.lang.String"]?.shallowBytes, 16)
        XCTAssertEqual(rows["char[]"]?.shallowBytes, 24)
    }

    func testParallelWorkersAgreeWithOne() async throws {
        var writer = HprofTestWriter()
        classes(&writer)
        for segmentIndex in 0..<40 {
            writer.segment { segment in
                for index in 0..<50 {
                    let id = UInt64(segmentIndex * 10_000 + index * 64 + 0x100_000)
                    switch index % 4 {
                    case 0: segment.instance(id, classID: string, fieldBytes: 13)
                    case 1: segment.instance(id, classID: derived, fieldBytes: 16)
                    case 2: segment.primitiveArray(id, type: .int, length: index)
                    default: segment.objectArray(id, classID: stringArray, elements: Array(repeating: 0, count: index % 7))
                    }
                }
            }
        }
        let one = try await read(writer, concurrency: 1)
        let many = try await read(writer, concurrency: 8, workItemBytes: 2_000)
        XCTAssertEqual(one.objectCount, 6 + 40 * 50)
        XCTAssertEqual(
            Set(one.histogram.rows.map { "\($0.name) \($0.count) \($0.shallowBytes)" }),
            Set(many.histogram.rows.map { "\($0.name) \($0.count) \($0.shallowBytes)" })
        )
    }

    func testUnknownSubRecordSkipsOnlyTheRestOfItsSegment() async throws {
        var writer = HprofTestWriter()
        classes(&writer)
        writer.segment { segment in
            segment.instance(0x1000, classID: string, fieldBytes: 13)
            segment.raw(Data([0x89, 1, 2, 3, 4]))
            segment.instance(0x2000, classID: string, fieldBytes: 13)
        }
        writer.segment { segment in
            segment.instance(0x3000, classID: string, fieldBytes: 13)
        }
        let overview = try await read(writer)
        XCTAssertEqual(overview.instanceCount, 2)
        XCTAssertEqual(overview.problems.count, 1)
        XCTAssertTrue(overview.problems[0].contains("0x89"), overview.problems[0])
    }

    func testTruncatedFileKeepsWhatWasRead() async throws {
        var writer = HprofTestWriter()
        classes(&writer)
        writer.segment { segment in
            segment.instance(0x1000, classID: string, fieldBytes: 13)
            segment.primitiveArray(0x2000, type: .byte, length: 4_000)
            segment.instance(0x3000, classID: string, fieldBytes: 13)
        }
        let full = writer.data()
        let url = directory.appendingPathComponent("cut.hprof")
        try full.prefix(full.count - 2_000).write(to: url)
        let overview = try await HeapDumpCensus.read(url, maxConcurrency: 2)
        XCTAssertNotNil(overview.truncatedAt)
        XCTAssertEqual(overview.instanceCount, 1)
        XCTAssertEqual(overview.primitiveArrayCount, 0, "the array that runs past the end is not counted")
        XCTAssertEqual(overview.problems.count, 1)
        XCTAssertTrue(overview.problems[0].contains("ends early"), overview.problems[0])
    }

    func testCancellationStopsTheRead() async throws {
        var writer = HprofTestWriter()
        classes(&writer)
        let url = directory.appendingPathComponent("cancel.hprof")
        try writer.write(to: url)
        let task = Task { try await HeapDumpCensus.read(url) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
    }

    func testReportsProgressToTheEnd() async throws {
        var writer = HprofTestWriter()
        classes(&writer)
        let url = directory.appendingPathComponent("progress.hprof")
        try writer.write(to: url)
        let seen = ProgressLog()
        _ = try await HeapDumpCensus.read(url, maxConcurrency: 2) { seen.append($0) }
        let phases = seen.values.map(\.phase)
        XCTAssertEqual(phases.first, .scanningRecords)
        XCTAssertEqual(phases.last, .summarizing)
        XCTAssertEqual(seen.values.map(\.fraction), seen.values.map(\.fraction).sorted())
    }

    /// `UMBRA_HPROF=<path>` reads a real dump (the 6.5 GB IntelliJ one, say) and checks invariants.
    func testRealDumpWhenGiven() async throws {
        guard let path = ProcessInfo.processInfo.environment["UMBRA_HPROF"] else {
            throw XCTSkip("Set UMBRA_HPROF to a .hprof file to run")
        }
        let overview = try await HeapDumpCensus.read(URL(fileURLWithPath: path))
        XCTAssertEqual(overview.problems, [])
        XCTAssertNil(overview.truncatedAt)
        XCTAssertGreaterThan(overview.objectCount, 0)
        XCTAssertEqual(overview.histogram.totalCount, overview.objectCount)
        XCTAssertNotNil(overview.layoutConfidence)
    }
}

final class HeapHistogramTests: XCTestCase {
    private let histogram = HeapHistogram(rows: [
        HeapClassRow(id: 0, name: "byte[]", kind: .primitiveArray, count: 10, shallowBytes: 1_000),
        HeapClassRow(id: 1, name: "java.util.HashMap$Node", kind: .instance, count: 5, shallowBytes: 160),
        HeapClassRow(id: 2, name: "java.util.HashMap", kind: .instance, count: 1, shallowBytes: 48),
        HeapClassRow(id: 3, name: "java.util.HashMap$Node[]", kind: .objectArray, count: 1, shallowBytes: 80),
        HeapClassRow(id: 4, name: "Main", kind: .instance, count: 1, shallowBytes: 16),
        HeapClassRow(id: 5, name: "int[][]", kind: .objectArray, count: 2, shallowBytes: 64)
    ])

    func testTotals() {
        XCTAssertEqual(histogram.totalCount, 20)
        XCTAssertEqual(histogram.totalShallowBytes, 1_368)
    }

    func testFilterIsASubstringOrAPattern() {
        XCTAssertEqual(histogram.filtered("hashmap").map(\.id), [1, 2, 3])
        XCTAssertEqual(histogram.filtered("java.util.*[]").map(\.id), [3])
        XCTAssertEqual(histogram.filtered("  ").count, 6)
    }

    func testPackagesOfClassesAndArrays() {
        XCTAssertEqual(histogram.rows[1].packageName, "java.util")
        XCTAssertEqual(histogram.rows[3].packageName, "java.util")
        XCTAssertEqual(histogram.rows[0].packageName, "(primitive arrays)")
        XCTAssertEqual(histogram.rows[5].packageName, "(primitive arrays)")
        XCTAssertEqual(histogram.rows[4].packageName, "(default package)")
    }

    func testGroupsByPackageLargestFirst() {
        let grouped = histogram.groupedByPackage()
        XCTAssertEqual(grouped.rows.map(\.name), ["(primitive arrays)", "java.util", "(default package)"])
        XCTAssertEqual(grouped.rows[1].count, 7)
        XCTAssertEqual(grouped.rows[1].shallowBytes, 288)
        XCTAssertEqual(grouped.rows[1].kind, .package)
        XCTAssertEqual(grouped.totalShallowBytes, histogram.totalShallowBytes)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [HeapDumpCensus.Progress] = []

    func append(_ value: HeapDumpCensus.Progress) {
        lock.lock()
        log.append(value)
        lock.unlock()
    }

    var values: [HeapDumpCensus.Progress] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }
}
