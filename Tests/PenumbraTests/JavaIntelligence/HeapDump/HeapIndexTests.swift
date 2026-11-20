import Foundation
@testable import JavaIntelligence
import XCTest

final class HeapIndexTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeapIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func build(
        _ writer: HprofTestWriter, name: String = "dump", concurrency: Int = 4, workItemBytes: Int64 = 64 << 20
    ) async throws -> HeapIndex {
        let url = directory.appendingPathComponent("\(name).hprof")
        try writer.write(to: url)
        return try await HeapIndexBuilder.build(
            dump: url, into: directory.appendingPathComponent("\(name)-index"), layout: .compressed,
            maxConcurrency: concurrency, workItemBytes: workItemBytes
        )
    }

    // Classes.
    private let objectClass: UInt64 = 0x100
    private let node: UInt64 = 0x110
    private let holder: UInt64 = 0x120
    private let reference: UInt64 = 0x130
    private let weakReference: UInt64 = 0x140
    private let nodeArray: UInt64 = 0x150
    // Objects, deliberately out of address order across and within segments.
    private let n1: UInt64 = 0x5000
    private let n2: UInt64 = 0x3000
    private let n3: UInt64 = 0x9000
    private let weak: UInt64 = 0x4000
    private let array: UInt64 = 0x8000
    private let bytes: UInt64 = 0x2000

    private func graph() -> HprofTestWriter {
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let next = writer.name("next", cache: &names)
        let value = writer.name("value", cache: &names)
        let instance = writer.name("INSTANCE", cache: &names)
        let count = writer.name("COUNT", cache: &names)
        let referent = writer.name("referent", cache: &names)
        let queue = writer.name("queue", cache: &names)
        writer.loadClass(objectClass, name: "java/lang/Object")
        writer.loadClass(node, name: "com/acme/Node")
        writer.loadClass(holder, name: "com/acme/Holder")
        writer.loadClass(reference, name: "java/lang/ref/Reference")
        writer.loadClass(weakReference, name: "java/lang/ref/WeakReference")
        writer.loadClass(nodeArray, name: "[Lcom/acme/Node;")
        writer.segment { s in
            s.classDump(objectClass)
            s.classDump(node, superID: objectClass, namedFields: [(next, .object), (value, .int)])
            s.classDump(holder, superID: objectClass, namedStatics: [(instance, .ref(n1)), (count, .int(5))])
            s.classDump(reference, superID: objectClass, namedFields: [(referent, .object), (queue, .object)])
            s.classDump(weakReference, superID: reference)
            s.classDump(nodeArray, superID: objectClass)
        }
        writer.segment { s in
            s.instance(n3, classID: node, values: [.ref(n1), .int(3)])
            s.objectArray(array, classID: nodeArray, elements: [n1, 0, n3, 0xDEAD])
            s.instance(n1, classID: node, values: [.ref(n2), .int(1)])
            s.root(.javaFrame, n1)
            s.root(.stickyClass, holder)
        }
        writer.segment { s in
            s.instance(n2, classID: node, values: [.ref(n3), .int(2)])
            s.instance(weak, classID: weakReference, values: [.ref(n2), .ref(0)])
            s.primitiveArray(bytes, type: .byte, length: 10)
        }
        return writer
    }

    func testNumbersObjectsByIDAndFollowsReferencesBothWays() async throws {
        let index = try await build(graph())
        XCTAssertEqual(index.objectCount, 12)
        let ids = (1...index.objectCount).map { index.id(of: Int32($0)) }
        XCTAssertEqual(ids, ids.sorted(), "numbers follow ids")
        for (offset, id) in ids.enumerated() {
            XCTAssertEqual(index.number(ofID: id), Int32(offset + 1))
        }
        XCTAssertNil(index.number(ofID: 0xDEAD))
        XCTAssertNil(index.number(ofID: 0))
        func n(_ id: UInt64) throws -> Int32 { try XCTUnwrap(index.number(ofID: id)) }

        XCTAssertEqual(index.outbound(of: try n(n1)), [HeapEdge(object: try n(n2), isWeak: false)])
        XCTAssertEqual(index.outbound(of: try n(n3)), [HeapEdge(object: try n(n1), isWeak: false)])
        XCTAssertEqual(index.outbound(of: try n(weak)), [HeapEdge(object: try n(n2), isWeak: true)], "Reference.referent is weak")
        XCTAssertEqual(index.outbound(of: try n(array)).map(\.object), [try n(n1), try n(n3)])
        XCTAssertEqual(index.danglingReferences, 1, "0xDEAD is not in the dump")
        XCTAssertEqual(index.outbound(of: try n(bytes)), [])
        // A class refers to its superclass and its static references.
        XCTAssertEqual(Set(index.outbound(of: try n(holder)).map(\.object)), [try n(objectClass), try n(n1)])
        XCTAssertEqual(index.outbound(of: try n(weakReference)).map(\.object), [try n(reference)])

        XCTAssertEqual(index.inboundCount(of: try n(n2)), 2)
        XCTAssertEqual(
            Set(index.inbound(of: try n(n2), range: 0..<10)),
            [HeapEdge(object: try n(n1), isWeak: false), HeapEdge(object: try n(weak), isWeak: true)]
        )
        XCTAssertEqual(Set(index.inbound(of: try n(n1), range: 0..<10).map(\.object)), [try n(n3), try n(array), try n(holder)])
        XCTAssertEqual(index.inbound(of: try n(n1), range: 1..<2).count, 1, "a page of referrers")
        XCTAssertEqual(index.referenceCount, index.outbound(of: 0).count + (1...12).reduce(0) { $0 + index.outbound(of: Int32($1)).count })

        XCTAssertEqual(index.referenceName(from: try n(n1), to: try n(n2)), "next")
        XCTAssertEqual(index.referenceName(from: try n(array), to: try n(n3)), "[2]")
        XCTAssertEqual(index.referenceName(from: try n(holder), to: try n(n1)), "static INSTANCE")
        XCTAssertEqual(index.referenceName(from: try n(weakReference), to: try n(reference)), "<superclass>")

        XCTAssertEqual(index.kind(of: try n(holder)), .classObject)
        XCTAssertEqual(index.kind(of: try n(array)), .objectArray)
        XCTAssertEqual(index.kind(of: try n(bytes)), .primitiveArray)
        XCTAssertEqual(index.className(of: try n(n1)), "com.acme.Node")
        XCTAssertEqual(index.className(of: try n(holder)), "java.lang.Class")
        XCTAssertEqual(index.title(of: try n(holder)), "class com.acme.Holder @ 0x120")
        XCTAssertEqual(index.length(of: try n(array)), 4)
        // Node: 12 + int + reference = 20 → 24; Node[4]: 16 + 16 = 32; byte[10]: 26 → 32.
        XCTAssertEqual(index.shallowSize(of: try n(n1)), 24)
        XCTAssertEqual(index.shallowSize(of: try n(array)), 32)
        XCTAssertEqual(index.shallowSize(of: try n(bytes)), 32)
        XCTAssertEqual(index.shallowSize(of: try n(n1), layout: .uncompressed), 32)

        XCTAssertEqual(index.roots.count, 2)
        XCTAssertEqual(index.roots.first { $0.kind == .javaFrame }?.object, try n(n1))
        XCTAssertEqual(index.roots.first { $0.kind == .stickyClass }?.object, try n(holder))
    }

    func testFieldsStaticsAndElementsDecode() async throws {
        let index = try await build(graph())
        func n(_ id: UInt64) throws -> Int32 { try XCTUnwrap(index.number(ofID: id)) }
        let fields = try index.fields(of: try n(n1))
        XCTAssertEqual(fields.map(\.name), ["next", "value"])
        XCTAssertEqual(fields.map(\.value), [.object(try n(n2)), .int(1)])
        // A subclass record: WeakReference has no fields of its own, Reference's follow.
        XCTAssertEqual(try index.fields(of: try n(weak)).map(\.name), ["referent", "queue"])
        XCTAssertEqual(try index.fields(of: try n(weak)).map(\.value), [.object(try n(n2)), .null])

        let statics = try index.fields(of: try n(holder))
        XCTAssertEqual(statics.map(\.name), ["<superclass>", "<class loader>", "static INSTANCE", "static COUNT"])
        XCTAssertEqual(statics.map(\.value), [.object(try n(objectClass)), .null, .object(try n(n1)), .int(5)])

        let elements = try index.fields(of: try n(array))
        XCTAssertEqual(elements.map(\.name), ["[0]", "[1]", "[2]", "[3]"])
        XCTAssertEqual(elements.map(\.value), [.object(try n(n1)), .null, .object(try n(n3)), .unresolved(0xDEAD)])
        XCTAssertEqual(try index.elements(of: try n(array), range: 2..<9).map(\.name), ["[2]", "[3]"])
        XCTAssertEqual(try index.fields(of: try n(bytes)).count, 10)
        XCTAssertEqual(try index.fields(of: try n(bytes)).first?.value, .byte(0))
    }

    func testInstancesByGroupAndHistogramRows() async throws {
        let writer = graph()
        let index = try await build(writer)
        let overview = try await HeapDumpCensus.read(directory.appendingPathComponent("dump.hprof"))
        for row in overview.histogram.rows {
            let group = try XCTUnwrap(index.groupIndex(for: row), row.name)
            XCTAssertEqual(index.instanceCount(ofGroup: group), row.count, row.name)
        }
        let nodeRow = try XCTUnwrap(overview.histogram.rows.first { $0.name == "com.acme.Node" })
        let group = try XCTUnwrap(index.groupIndex(for: nodeRow))
        XCTAssertEqual(index.instances(ofGroup: group, order: .address).map { index.id(of: $0) }, [n2, n1, n3])
        XCTAssertEqual(index.instances(ofGroup: group, limit: 2).count, 2)
        XCTAssertEqual(index.instances(ofGroup: index.mirrorGroup).count, 6)
    }

    func testLargestArraysFirst() async throws {
        var writer = HprofTestWriter()
        writer.segment { s in
            for (offset, length) in [5, 100, 1, 64, 64, 7].enumerated() {
                s.primitiveArray(UInt64(0x1000 + offset * 0x100), type: .int, length: length)
            }
        }
        let index = try await build(writer)
        let group = index.classes.firstIndex { $0.name == "int[]" }.map(Int32.init)!
        let largest = index.instances(ofGroup: group, limit: 3)
        XCTAssertEqual(largest.map { index.length(of: $0) }, [100, 64, 64])
        XCTAssertEqual(index.instances(ofGroup: group, order: .address).map { index.length(of: $0) }, [5, 100, 1, 64, 64, 7])
    }

    // MARK: - Previews

    func testPreviewsOfStringsBoxesEnumsCollectionsAndArrays() async throws {
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let value = writer.name("value", cache: &names)
        let coder = writer.name("coder", cache: &names)
        let hash = writer.name("hash", cache: &names)
        let name = writer.name("name", cache: &names)
        let ordinal = writer.name("ordinal", cache: &names)
        let size = writer.name("size", cache: &names)
        let elementData = writer.name("elementData", cache: &names)
        let object: UInt64 = 0x100, string: UInt64 = 0x110, integer: UInt64 = 0x120, enumClass: UInt64 = 0x130
        let state: UInt64 = 0x140, list: UInt64 = 0x150
        writer.loadClass(object, name: "java/lang/Object")
        writer.loadClass(string, name: "java/lang/String")
        writer.loadClass(integer, name: "java/lang/Integer")
        writer.loadClass(enumClass, name: "java/lang/Enum")
        writer.loadClass(state, name: "java/lang/Thread$State")
        writer.loadClass(list, name: "java/util/ArrayList")
        let utf16 = Array("hé€".utf16)
        var utf16Bytes = Data()
        for unit in utf16 { utf16Bytes.append(UInt8(unit & 0xFF)); utf16Bytes.append(UInt8(unit >> 8)) }
        var charBytes = Data()
        for unit in Array("chars".utf16) { charBytes.appendU2(unit) }
        let long = String(repeating: "x", count: 300)
        writer.segment { s in
            s.classDump(object)
            s.classDump(string, superID: object, namedFields: [(value, .object), (coder, .byte), (hash, .int)])
            s.classDump(integer, superID: object, namedFields: [(value, .int)])
            s.classDump(enumClass, superID: object, namedFields: [(name, .object), (ordinal, .int)])
            s.classDump(state, superID: enumClass)
            s.classDump(list, superID: object, namedFields: [(size, .int), (elementData, .object)])
            s.primitiveArray(0x1000, type: .byte, count: 5, elements: Data("hello".utf8))
            s.instance(0x1100, classID: string, values: [.ref(0x1000), .byte(0), .int(0)])
            s.primitiveArray(0x1200, type: .byte, count: utf16Bytes.count, elements: utf16Bytes)
            s.instance(0x1300, classID: string, values: [.ref(0x1200), .byte(1), .int(0)])
            s.primitiveArray(0x1400, type: .byte, count: long.utf8.count, elements: Data(long.utf8))
            s.instance(0x1500, classID: string, values: [.ref(0x1400), .byte(0), .int(0)])
            s.instance(0x1600, classID: integer, values: [.int(42)])
            s.primitiveArray(0x1700, type: .byte, count: 8, elements: Data("RUNNABLE".utf8))
            s.instance(0x1800, classID: string, values: [.ref(0x1700), .byte(0), .int(0)])
            s.instance(0x1900, classID: state, values: [.ref(0x1800), .int(1)])
            s.objectArray(0x2000, classID: object, elements: [0x1100, 0x1600, 0])
            s.instance(0x2100, classID: list, values: [.int(3), .ref(0x2000)])
            s.primitiveArray(0x2200, type: .char, count: 5, elements: charBytes)
        }
        let index = try await build(writer)
        func preview(_ id: UInt64) throws -> String? { index.preview(of: try XCTUnwrap(index.number(ofID: id))) }
        XCTAssertEqual(try preview(0x1100), "\"hello\"")
        XCTAssertEqual(try preview(0x1300), "\"hé€\"")
        XCTAssertEqual(try preview(0x1500), "\"" + String(repeating: "x", count: 120) + "…\"")
        XCTAssertEqual(try preview(0x1600), "42")
        XCTAssertEqual(try preview(0x1900), "RUNNABLE")
        XCTAssertEqual(try preview(0x2100), "size 3")
        XCTAssertEqual(try preview(0x2000), "length 3")
        XCTAssertEqual(try preview(0x2200), "\"chars\"")
        XCTAssertEqual(try preview(string), "java.lang.String")
        XCTAssertEqual(try preview(0x1000), "length 5", "a byte[] is not text")
    }

    func testJDK8StringsUseCharArrays() async throws {
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let value = writer.name("value", cache: &names)
        let hash = writer.name("hash", cache: &names)
        writer.loadClass(0x100, name: "java/lang/Object")
        writer.loadClass(0x110, name: "java/lang/String")
        var chars = Data()
        for unit in Array("jdk8".utf16) { chars.appendU2(unit) }
        writer.segment { s in
            s.classDump(0x100)
            s.classDump(0x110, superID: 0x100, namedFields: [(value, .object), (hash, .int)])
            s.primitiveArray(0x1000, type: .char, count: 4, elements: chars)
            s.instance(0x1100, classID: 0x110, values: [.ref(0x1000), .int(0)])
        }
        let index = try await build(writer)
        XCTAssertEqual(index.preview(of: try XCTUnwrap(index.number(ofID: 0x1100))), "\"jdk8\"")
    }

    // MARK: - Against a naive model

    func testRandomGraphMatchesANaiveModel() async throws {
        var random = SeededRandom(seed: 0x5EED)
        var writer = HprofTestWriter()
        var names: [String: UInt64] = [:]
        let a = writer.name("a", cache: &names)
        let b = writer.name("b", cache: &names)
        let c = writer.name("c", cache: &names)
        let x = writer.name("x", cache: &names)
        let object: UInt64 = 0x100, pair: UInt64 = 0x110, single: UInt64 = 0x120, objects: UInt64 = 0x130
        writer.loadClass(object, name: "java/lang/Object")
        writer.loadClass(pair, name: "Pair")
        writer.loadClass(single, name: "Single")
        writer.loadClass(objects, name: "[Ljava/lang/Object;")
        writer.segment { s in
            s.classDump(object)
            s.classDump(pair, superID: object, namedFields: [(a, .object), (b, .object)])
            s.classDump(single, superID: object, namedFields: [(c, .object), (x, .int)])
            s.classDump(objects, superID: object)
        }
        let count = 1_500
        let ids = (0..<count).map { UInt64(0x10_0000 + $0 * 32) }
        func target() -> UInt64 {
            switch random.next() % 10 {
            case 0: return 0
            case 1: return 0xBAD0_0000 + random.next() % 100
            default: return ids[Int(random.next() % UInt64(count))]
            }
        }
        var expected: [UInt64: [UInt64]] = [:]
        var records: [(UInt64, (inout HeapSegmentWriter) -> Void)] = []
        for id in ids {
            switch random.next() % 3 {
            case 0:
                let (t1, t2) = (target(), target())
                expected[id] = [t1, t2].filter { ids.contains($0) }
                records.append((id, { $0.instance(id, classID: pair, values: [.ref(t1), .ref(t2)]) }))
            case 1:
                let t = target()
                expected[id] = [t].filter { ids.contains($0) }
                records.append((id, { $0.instance(id, classID: single, values: [.ref(t), .int(7)]) }))
            default:
                let elements = (0..<Int(random.next() % 6)).map { _ in target() }
                expected[id] = elements.filter { ids.contains($0) }
                records.append((id, { $0.objectArray(id, classID: objects, elements: elements) }))
            }
        }
        // Shuffled into fifteen segments, so the merge has real work.
        var shuffled = records
        for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
            shuffled.swapAt(i, Int(random.next() % UInt64(i + 1)))
        }
        for chunk in stride(from: 0, to: shuffled.count, by: 100) {
            writer.segment { s in
                for (_, write) in shuffled[chunk..<min(chunk + 100, shuffled.count)] { write(&s) }
            }
        }

        let parallel = try await build(writer, name: "parallel", concurrency: 8, workItemBytes: 512)
        let single1 = try await build(writer, name: "single", concurrency: 1)
        for index in [parallel, single1] {
            XCTAssertEqual(index.objectCount, count + 4)
            var inbound: [UInt64: [UInt64]] = [:]
            for id in ids {
                let n = try XCTUnwrap(index.number(ofID: id))
                XCTAssertEqual(index.outbound(of: n).map { index.id(of: $0.object) }, expected[id], String(id, radix: 16))
                for to in expected[id] ?? [] { inbound[to, default: []].append(id) }
            }
            for id in ids {
                let n = try XCTUnwrap(index.number(ofID: id))
                let referrers = index.inbound(of: n, range: 0..<index.inboundCount(of: n))
                    .map { index.id(of: $0.object) }
                    .filter { ids.contains($0) }
                XCTAssertEqual(referrers.sorted(), (inbound[id] ?? []).sorted(), String(id, radix: 16))
            }
        }
    }

    // MARK: - Store

    func testTheStoreReusesACompleteIndexAndDropsStaleOrPartialOnes() async throws {
        let dump = directory.appendingPathComponent("stored.hprof")
        try graph().write(to: dump)
        let store = HeapIndexStore(root: directory.appendingPathComponent("indexes"))
        XCTAssertNil(store.openExisting(for: dump))
        let built = try await store.build(dump: dump, layout: .compressed)
        let folder = try store.directory(for: dump)
        XCTAssertEqual(built.directory, folder)
        XCTAssertGreaterThan(built.diskBytes, 0)

        let reopened = try XCTUnwrap(store.openExisting(for: dump))
        XCTAssertEqual(reopened.objectCount, built.objectCount)
        XCTAssertEqual(reopened.referenceCount, built.referenceCount)
        XCTAssertEqual(reopened.classes, built.classes)
        XCTAssertEqual(reopened.outbound(of: 7), built.outbound(of: 7))

        // Incomplete: the marker is gone.
        try FileManager.default.removeItem(at: folder.appendingPathComponent(HeapIndexBuilder.Files.complete))
        XCTAssertNil(store.openExisting(for: dump))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a partial index is removed")

        // Stale: the dump changed after the build, so its folder name changes too.
        _ = try await store.build(dump: dump, layout: .compressed)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: dump.path)
        XCTAssertNil(store.openExisting(for: dump))
        store.delete(for: dump)
    }

    func testACancelledBuildLeavesNothingBehind() async throws {
        let dump = directory.appendingPathComponent("cancel.hprof")
        try graph().write(to: dump)
        let target = directory.appendingPathComponent("cancel-index")
        let task = Task { try await HeapIndexBuilder.build(dump: dump, into: target, layout: .compressed) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// `UMBRA_HPROF=<path>` builds the index of a real dump in a temporary folder and checks it.
    func testRealDumpIndexWhenGiven() async throws {
        guard let path = ProcessInfo.processInfo.environment["UMBRA_HPROF"] else {
            throw XCTSkip("Set UMBRA_HPROF to a .hprof file to run")
        }
        let url = URL(fileURLWithPath: path)
        let overview = try await HeapDumpCensus.read(url)
        let started = Date()
        let index = try await HeapIndexBuilder.build(dump: url, into: directory.appendingPathComponent("real"), layout: overview.layout)
        print("HEAPINDEX objects=\(index.objectCount) references=\(index.referenceCount) dangling=\(index.danglingReferences) seconds=\(Date().timeIntervalSince(started)) bytes=\(index.diskBytes)")
        XCTAssertEqual(index.objectCount, overview.objectCount)
        var random = SeededRandom(seed: 7)
        for _ in 0..<20_000 {
            let n = Int32(1 + random.next() % UInt64(index.objectCount))
            XCTAssertEqual(index.number(ofID: index.id(of: n)), n)
        }
        for row in overview.histogram.rows.prefix(200) {
            let group = try XCTUnwrap(index.groupIndex(for: row), row.name)
            XCTAssertEqual(index.instanceCount(ofGroup: group), row.count, row.name)
        }
        if let string = overview.histogram.rows.first(where: { $0.name == "java.lang.String" }),
           let group = index.groupIndex(for: string), let first = index.instances(ofGroup: group, limit: 1).first {
            XCTAssertNotNil(index.preview(of: first))
        }
    }
}

/// SplitMix64: the same sequence on every run.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class HeapIndexStoreSweepTests: XCTestCase {
    private var directory: URL!
    private var store: HeapIndexStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeapIndexSweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = HeapIndexStore(root: directory.appendingPathComponent("indexes"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func dump(_ name: String) throws -> URL {
        var writer = HprofTestWriter()
        writer.loadClass(0x100, name: "java/lang/Object")
        writer.segment { s in
            s.classDump(0x100)
            for index in 0..<50 { s.primitiveArray(UInt64(0x1000 + index * 0x100), type: .int, length: 8) }
        }
        let url = directory.appendingPathComponent("\(name).hprof")
        try writer.write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testIndexesOfDeletedMovedOrChangedDumpsAreRemoved() async throws {
        let deleted = try dump("deleted")
        let moved = try dump("moved")
        let changed = try dump("changed")
        let kept = try dump("kept")
        var folders: [String: URL] = [:]
        for (name, url) in [("deleted", deleted), ("moved", moved), ("changed", changed), ("kept", kept)] {
            folders[name] = try await store.build(dump: url, layout: .compressed).directory
        }
        try FileManager.default.removeItem(at: deleted)
        try FileManager.default.moveItem(at: moved, to: directory.appendingPathComponent("elsewhere.hprof"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: changed.path)

        let result = store.sweep()
        XCTAssertEqual(Set(result.removed.map(\.lastPathComponent)), Set(["deleted", "moved", "changed"].map { folders[$0]!.lastPathComponent }))
        XCTAssertGreaterThan(result.freedBytes, 0)
        XCTAssertTrue(exists(folders["kept"]!))
        XCTAssertNotNil(store.openExisting(for: kept))
    }

    func testAbandonedBuildsGoAndOneInProgressStays() throws {
        let root = store.root
        let abandoned = root.appendingPathComponent("abandoned-1", isDirectory: true)
        let running = root.appendingPathComponent("running-2", isDirectory: true)
        for folder in [abandoned, running] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 64).write(to: folder.appendingPathComponent("ids.u64"))
        }
        let old = Date().addingTimeInterval(-HeapIndexStore.abandonedBuildAge - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: abandoned.path)
        let result = store.sweep()
        XCTAssertEqual(result.removed.map(\.lastPathComponent), ["abandoned-1"])
        XCTAssertTrue(exists(running))
    }

    func testOverTheCapTheLeastRecentlyUsedGoButNotTheOneKept() async throws {
        let first = try dump("first")
        let second = try dump("second")
        let third = try dump("third")
        let a = try await store.build(dump: first, layout: .compressed).directory
        let b = try await store.build(dump: second, layout: .compressed).directory
        let c = try await store.build(dump: third, layout: .compressed).directory
        // Used order: b long ago, a, then c (just opened).
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: b.appendingPathComponent("last-used").path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-200)], ofItemAtPath: a.appendingPathComponent("last-used").path)
        _ = store.openExisting(for: third)
        let one = HeapIndexStore.size(of: a)
        // Room for two: the least recently used of the rest goes, the kept one stays.
        let result = store.sweep(maximumBytes: one * 2 + one / 2, keeping: [b])
        XCTAssertEqual(result.removed.map(\.lastPathComponent), [a.lastPathComponent])
        XCTAssertTrue(exists(b), "kept even though it is the oldest")
        XCTAssertTrue(exists(c))
    }
}
