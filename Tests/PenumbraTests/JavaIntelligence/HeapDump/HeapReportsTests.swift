import Foundation
@testable import JavaIntelligence
import XCTest

final class HeapReportsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeapReportsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func build(_ writer: HprofTestWriter, name: String = "dump") async throws -> HeapIndex {
        let url = directory.appendingPathComponent("\(name).hprof")
        try writer.write(to: url)
        return try await HeapIndexBuilder.build(dump: url, into: directory.appendingPathComponent("\(name)-index"), layout: .compressed)
    }

    // MARK: - Leak suspects

    /// Holder → Registry → Object[] → 200 Nodes, each with a 1 KB payload; ten small Boxes beside.
    private func leakyDump(boxes: Int = 10) -> HprofTestWriter {
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let registry = writer.name("registry", cache: &names)
        let entries = writer.name("entries", cache: &names)
        let payload = writer.name("payload", cache: &names)
        writer.loadClass(0x100, name: "java/lang/Object")
        writer.loadClass(0x110, name: "app/Holder")
        writer.loadClass(0x120, name: "app/Registry")
        writer.loadClass(0x130, name: "app/Node")
        writer.loadClass(0x140, name: "[Ljava/lang/Object;")
        writer.loadClass(0x150, name: "app/Box")
        writer.segment { s in
            s.classDump(0x100)
            s.classDump(0x110, superID: 0x100, namedFields: [(registry, .object)])
            s.classDump(0x120, superID: 0x100, namedFields: [(entries, .object)])
            s.classDump(0x130, superID: 0x100, namedFields: [(payload, .object)])
            s.classDump(0x140, superID: 0x100)
            s.classDump(0x150, superID: 0x100, namedFields: [(payload, .object)])
            s.instance(0x1000, classID: 0x110, values: [.ref(0x1100)])
            s.instance(0x1100, classID: 0x120, values: [.ref(0x1200)])
            let nodes = (0..<200).map { UInt64(0x10_0000 + $0 * 0x1000) }
            s.objectArray(0x1200, classID: 0x140, elements: nodes)
            for node in nodes {
                s.instance(node, classID: 0x130, values: [.ref(node + 0x800)])
                s.primitiveArray(node + 0x800, type: .byte, length: 1024)
            }
            s.root(.javaFrame, 0x1000)
            for box in 0..<boxes {
                let id = UInt64(0x50_0000 + box * 0x1000)
                s.instance(id, classID: 0x150, values: [.ref(id + 0x800)])
                s.primitiveArray(id + 0x800, type: .byte, length: 64)
                s.root(.jniGlobal, id)
            }
        }
        return writer
    }

    func testASingleHolderIsASuspectWithItsAccumulationPoint() async throws {
        let index = try await build(leakyDump())
        let suspects = HeapLeakSuspects.find(in: index)
        XCTAssertEqual(suspects.count, 1)
        let suspect = try XCTUnwrap(suspects.first)
        XCTAssertEqual(suspect.kind, .object)
        XCTAssertEqual(suspect.className, "app.Holder")
        XCTAssertGreaterThan(suspect.share, 0.9)
        XCTAssertEqual(suspect.accumulationTitle, "java.lang.Object[] @ 0x1200", "down through the registry to its array")
        XCTAssertEqual(suspect.accumulationChildCount, 200)
        XCTAssertEqual(suspect.accumulationChildClass, "app.Node")
        XCTAssertEqual(suspect.accumulationChildClassCount, 200)
        XCTAssertEqual(suspect.rootKinds, ["Java frame"])
        XCTAssertEqual(suspect.biggestClasses.first?.name, "byte[]")
        XCTAssertEqual(suspect.loaderTitle, "the bootstrap loader")
        XCTAssertTrue(suspect.summary.hasPrefix("One instance of app.Holder loaded by the bootstrap loader occupies"), suspect.summary)
        XCTAssertTrue(suspect.summary.contains("accumulated in one instance of java.lang.Object[], which keeps 200 objects alive directly, all app.Node."), suspect.summary)
    }

    func testManySmallInstancesOfOneClassAddUpToASuspect() async throws {
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let payload = writer.name("payload", cache: &names)
        writer.loadClass(0x100, name: "java/lang/Object")
        writer.loadClass(0x150, name: "app/Chunk")
        writer.segment { s in
            s.classDump(0x100)
            s.classDump(0x150, superID: 0x100, namedFields: [(payload, .object)])
            for chunk in 0..<40 {
                let id = UInt64(0x50_0000 + chunk * 0x1000)
                s.instance(id, classID: 0x150, values: [.ref(id + 0x800)])
                s.primitiveArray(id + 0x800, type: .byte, length: 512)
                s.root(.jniGlobal, id)
            }
        }
        let index = try await build(writer)
        let suspects = HeapLeakSuspects.find(in: index)
        XCTAssertEqual(suspects.map(\.kind), [.classGroup])
        XCTAssertEqual(suspects.first?.instanceCount, 40)
        let summary = try XCTUnwrap(suspects.first?.summary)
        XCTAssertTrue(summary.hasPrefix("40 instances of app.Chunk"), summary)
        XCTAssertFalse(summary.contains("accumulated"), "a group has no single accumulation point")
        XCTAssertTrue(summary.contains("The largest one keeps"), summary)
        XCTAssertNil(suspects.first?.accumulation)
    }

    func testChainsCollapseRepeatsAndKeepTheirEnds() {
        XCTAssertEqual(HeapLeakSuspects.compactChain(["A", "B", "B", "B", "C"]), "A → B ×3 → C")
        XCTAssertEqual(HeapLeakSuspects.compactChain(["Root"] + Array(repeating: "Segment", count: 4_000) + ["Leaf"]), "Root → Segment ×4,000 → Leaf")
        let long = (0..<12).map { "S\($0)" }
        XCTAssertEqual(HeapLeakSuspects.compactChain(long), "S0 → S1 → S2 → … 6 more … → S9 → S10 → S11")
    }

    func testNothingOverTheThresholdMeansNoSuspect() async throws {
        let index = try await build(leakyDump())
        XCTAssertEqual(HeapLeakSuspects.find(in: index, threshold: 1.0).count, 0, "the boxes are live too, so no one object holds it all")
    }

    // MARK: - Inspections

    private func stringDump() -> HprofTestWriter {
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let value = writer.name("value", cache: &names)
        let coder = writer.name("coder", cache: &names)
        let hash = writer.name("hash", cache: &names)
        writer.loadClass(0x100, name: "java/lang/Object")
        writer.loadClass(0x110, name: "java/lang/String")
        writer.segment { s in
            s.classDump(0x100)
            s.classDump(0x110, superID: 0x100, namedFields: [(value, .object), (coder, .byte), (hash, .int)])
            func string(_ id: UInt64, _ array: UInt64, _ text: String?, rooted: Bool = true) {
                if let text { s.primitiveArray(array, type: .byte, count: text.utf8.count, elements: Data(text.utf8)) }
                s.instance(id, classID: 0x110, values: [.ref(array), .byte(0), .int(0)])
                if rooted { s.root(.jniGlobal, id) }
            }
            string(0x1000, 0x1100, "hello")
            string(0x2000, 0x2100, "hello")
            string(0x3000, 0x3100, "hello")
            string(0x4000, 0x4100, "x")
            string(0x5000, 0x4100, nil)          // shares the "x" array
            string(0x6000, 0x6100, "world")
            string(0x7000, 0x7100, "hello", rooted: false)  // garbage: not counted
        }
        return writer
    }

    func testDuplicateStringsByTextWithSharedArraysCountedOnce() async throws {
        let index = try await build(stringDump())
        let report = try HeapInspections.duplicateStrings(in: index)
        XCTAssertEqual(report.stringCount, 6)
        XCTAssertEqual(report.distinctCount, 3)
        XCTAssertEqual(report.groups.map(\.text), ["hello", "x"])
        XCTAssertEqual(report.groups.map(\.count), [3, 2])
        // String 12 + 4 + 1 + 4 → 24; byte[5] 16 + 5 → 24; the shared "x" array wastes nothing.
        XCTAssertEqual(report.groups.map(\.wastedBytes), [2 * 24 + 2 * 24, 24])
        XCTAssertEqual(report.wastedBytes, 120)
        // A second call reads the saved result.
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.directory.appendingPathComponent("report-duplicate-strings.json").path))
        XCTAssertEqual(try HeapInspections.duplicateStrings(in: index).wastedBytes, 120)
    }

    func testEmptyAndSparseCollections() async throws {
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let size = writer.name("size", cache: &names)
        let elementData = writer.name("elementData", cache: &names)
        let table = writer.name("table", cache: &names)
        writer.loadClass(0x100, name: "java/lang/Object")
        writer.loadClass(0x110, name: "java/util/ArrayList")
        writer.loadClass(0x120, name: "java/util/HashMap")
        writer.loadClass(0x130, name: "[Ljava/lang/Object;")
        writer.segment { s in
            s.classDump(0x100)
            s.classDump(0x110, superID: 0x100, namedFields: [(size, .int), (elementData, .object)])
            s.classDump(0x120, superID: 0x100, namedFields: [(size, .int), (table, .object)])
            s.classDump(0x130, superID: 0x100)
            s.objectArray(0x1100, classID: 0x130, elements: Array(repeating: 0, count: 10))
            s.instance(0x1000, classID: 0x110, values: [.int(0), .ref(0x1100)])       // empty, 10 slots
            s.objectArray(0x2100, classID: 0x130, elements: [0x1000, 0x1000] + Array(repeating: 0, count: 98))
            s.instance(0x2000, classID: 0x110, values: [.int(2), .ref(0x2100)])       // 2 of 100
            s.objectArray(0x3100, classID: 0x130, elements: [])
            s.instance(0x3000, classID: 0x110, values: [.int(0), .ref(0x3100)])       // the shared empty array: fine
            s.objectArray(0x4100, classID: 0x130, elements: Array(repeating: 0, count: 16))
            s.instance(0x4000, classID: 0x120, values: [.int(0), .ref(0x4100)])       // empty map with a table
            for id: UInt64 in [0x1000, 0x2000, 0x3000, 0x4000] { s.root(.jniGlobal, id) }
        }
        let index = try await build(writer)
        let report = try HeapInspections.wastedCollections(in: index)
        let rows = Dictionary(uniqueKeysWithValues: report.rows.map { ("\($0.className) \($0.problem)", $0) })
        XCTAssertEqual(rows["java.util.ArrayList empty"]?.count, 1)
        XCTAssertEqual(rows["java.util.ArrayList empty"]?.wastedBytes, 56, "Object[10]: 16 + 40")
        XCTAssertEqual(rows["java.util.ArrayList sparse"]?.wastedBytes, 98 * 4)
        XCTAssertEqual(rows["java.util.HashMap empty"]?.wastedBytes, 16 + 64)
        XCTAssertEqual(report.rows.count, 3)
        XCTAssertEqual(report.rows.first?.className, "java.util.ArrayList", "largest waste first")
    }

    func testAllZeroArraysOfAKilobyteOrMore() async throws {
        var writer = HprofTestWriter()
        writer.segment { s in
            s.primitiveArray(0x1000, type: .byte, count: 2048, elements: Data(count: 2048))
            var dirty = Data(count: 2048)
            dirty[2047] = 1
            s.primitiveArray(0x2000, type: .byte, count: 2048, elements: dirty)
            s.primitiveArray(0x3000, type: .byte, count: 100, elements: Data(count: 100))
            s.primitiveArray(0x4000, type: .long, count: 512, elements: Data(count: 4096))
            s.primitiveArray(0x5000, type: .byte, count: 4096, elements: Data(count: 4096))  // garbage
            for id: UInt64 in [0x1000, 0x2000, 0x3000, 0x4000] { s.root(.jniGlobal, id) }
        }
        let index = try await build(writer)
        let report = try HeapInspections.zeroArrays(in: index)
        XCTAssertEqual(report.rows.map(\.className).sorted(), ["byte[]", "long[]"])
        XCTAssertEqual(report.rows.first { $0.className == "byte[]" }?.count, 1)
        XCTAssertEqual(report.rows.first { $0.className == "long[]" }?.examples.map { index.id(of: $0) }, [0x4000])
    }

    // MARK: - Threads

    func testThreadsWithStacksLocalsNameAndState() async throws {
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let value = writer.name("value", cache: &names)
        let coder = writer.name("coder", cache: &names)
        let name = writer.name("name", cache: &names)
        let status = writer.name("threadStatus", cache: &names)
        writer.loadClass(0x100, name: "java/lang/Object", serial: 1)
        writer.loadClass(0x110, name: "java/lang/String", serial: 2)
        writer.loadClass(0x120, name: "java/lang/Thread", serial: 3)
        writer.loadClass(0x130, name: "app/Main", serial: 4)
        writer.stackFrame(0xF1, method: "work", signature: "()V", file: "Main.java", classSerial: 4, line: 42)
        writer.stackFrame(0xF2, method: "main", signature: "([Ljava/lang/String;)V", file: "Main.java", classSerial: 4, line: 10)
        writer.stackFrame(0xF3, method: "sleep0", signature: "(J)V", file: nil, classSerial: 3, line: -3)
        writer.stackTrace(serial: 7, threadSerial: 1, frames: [0xF3, 0xF1, 0xF2])
        writer.segment { s in
            s.classDump(0x100)
            s.classDump(0x110, superID: 0x100, namedFields: [(value, .object), (coder, .byte)])
            s.classDump(0x120, superID: 0x100, namedFields: [(name, .object), (status, .int)])
            s.classDump(0x130, superID: 0x100)
            s.primitiveArray(0x1100, type: .byte, count: 4, elements: Data("main".utf8))
            s.instance(0x1000, classID: 0x110, values: [.ref(0x1100), .byte(0)])
            s.instance(0x2000, classID: 0x120, values: [.ref(0x1000), .int(0x5)])  // alive, runnable
            s.root(.threadObject, 0x2000, first: 1, second: 7)
            s.primitiveArray(0x3000, type: .int, length: 4)
            s.primitiveArray(0x4000, type: .int, length: 8)
            s.primitiveArray(0x5000, type: .int, length: 2)
            s.root(.javaFrame, 0x3000, first: 1, second: 1)   // a local of work()
            s.root(.javaFrame, 0x4000, first: 1, second: 2)   // a local of main()
            s.root(.jniLocal, 0x5000, first: 1, second: 0xFFFF_FFFF)
        }
        let index = try await build(writer)
        let threads = index.threads()
        XCTAssertEqual(threads.count, 1)
        let thread = try XCTUnwrap(threads.first)
        let object = try XCTUnwrap(thread.object)
        XCTAssertEqual(index.threadName(object), "main")
        XCTAssertEqual(index.threadState(object), .runnable)
        XCTAssertEqual(thread.frames.map(\.description), [
            "java.lang.Thread.sleep0(Native Method)", "app.Main.work(Main.java:42)", "app.Main.main(Main.java:10)"
        ])
        XCTAssertEqual(thread.frames.map { $0.locals.map { index.id(of: $0) } }, [[], [0x3000], [0x4000]])
        XCTAssertEqual(thread.unplacedLocals.map { index.id(of: $0) }, [0x5000])
        XCTAssertEqual(HeapThreadState(jvmtiStatus: 0x401), .blocked)
        XCTAssertEqual(HeapThreadState(jvmtiStatus: 0x91), .waiting)
        XCTAssertEqual(HeapThreadState(jvmtiStatus: 0xA1), .timedWaiting)
    }
}
