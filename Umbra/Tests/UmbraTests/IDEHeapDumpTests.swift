import AppKit
import Foundation
import JavaIntelligence
import Penumbra
import SwiftUI
import XCTest
@testable import Umbra

/// A small HPROF 1.0.2 file: Object, String (int, ref) and `com.acme.Cache` (ref), three Strings,
/// one Cache, a `byte[16]` and two roots. Written by hand here because `HprofTestWriter` lives in
/// the library's test target.
private func tinyHeapDump(weak: Bool = false) -> Data {
    var records = Data()
    func u4(_ value: UInt32, into data: inout Data) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    func u8(_ value: UInt64, into data: inout Data) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    func u2(_ value: UInt16, into data: inout Data) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    func record(_ tag: UInt8, _ body: Data) {
        records.append(tag)
        u4(0, into: &records)
        u4(UInt32(body.count), into: &records)
        records.append(body)
    }
    func loadClass(_ id: UInt64, _ name: String) {
        var string = Data()
        u8(id + 0x1000, into: &string)
        string.append(Data(name.utf8))
        record(0x01, string)
        var body = Data()
        u4(1, into: &body)
        u8(id, into: &body)
        u4(0, into: &body)
        u8(id + 0x1000, into: &body)
        record(0x02, body)
    }
    // Field names: String (hash, value), Cache (entry).
    for (id, name) in [(UInt64(0x9200), "hash"), (0x9201, "value"), (0x9300, "entry"), (0x9400, "referent")] {
        var string = Data()
        u8(id, into: &string)
        string.append(Data(name.utf8))
        record(0x01, string)
    }
    loadClass(0x10, "java/lang/Object")
    loadClass(0x20, "java/lang/String")
    loadClass(0x30, "com/acme/Cache")
    if weak {
        loadClass(0x40, "java/lang/ref/Reference")
        loadClass(0x50, "java/lang/ref/WeakReference")
    }
    var heap = Data()
    func classDump(_ id: UInt64, superID: UInt64, fields: [UInt8]) {
        heap.append(0x20)
        u8(id, into: &heap)
        u4(0, into: &heap)
        u8(superID, into: &heap)
        for _ in 0..<5 { u8(0, into: &heap) }
        u4(0, into: &heap)
        u2(0, into: &heap)
        u2(0, into: &heap)
        u2(UInt16(fields.count), into: &heap)
        for (index, type) in fields.enumerated() {
            u8(UInt64(0x9000 + Int(id) * 16 + index), into: &heap)
            heap.append(type)
        }
    }
    func instance(_ id: UInt64, classID: UInt64, fieldBytes: Int, fields: Data? = nil) {
        heap.append(0x21)
        u8(id, into: &heap)
        u4(0, into: &heap)
        u8(classID, into: &heap)
        u4(UInt32(fieldBytes), into: &heap)
        heap.append(fields ?? Data(count: fieldBytes))
    }
    classDump(0x10, superID: 0, fields: [])
    classDump(0x20, superID: 0x10, fields: [10, 2])
    classDump(0x30, superID: 0x10, fields: [2])
    for index in 0..<3 { instance(UInt64(0x10_0000 + index * 0x1000), classID: 0x20, fieldBytes: 12) }
    if weak {
        // A frame holds a WeakReference to the second String: only weakly reachable.
        classDump(0x40, superID: 0x10, fields: [2])
        classDump(0x50, superID: 0x40, fields: [])
        var referent = Data()
        u8(0x10_1000, into: &referent)
        instance(0x50_0000, classID: 0x50, fieldBytes: 8, fields: referent)
        heap.append(0x03)
        u8(0x50_0000, into: &heap)
        u4(1, into: &heap)
        u4(1, into: &heap)
    }
    // The cache's entry is the first String.
    var entry = Data()
    u8(0x10_0000, into: &entry)
    instance(0x20_0000, classID: 0x30, fieldBytes: 8, fields: entry)
    heap.append(0x23)
    u8(0x30_0000, into: &heap)
    u4(0, into: &heap)
    u4(16, into: &heap)
    heap.append(8)
    heap.append(Data(count: 16))
    heap.append(0x08)
    u8(0x40_0000, into: &heap)
    u4(1, into: &heap)
    u4(0, into: &heap)
    heap.append(0x05)
    u8(0x20, into: &heap)
    // The cache is held by a Java frame: it and its entry are live, the other strings garbage.
    heap.append(0x03)
    u8(0x20_0000, into: &heap)
    u4(1, into: &heap)
    u4(0, into: &heap)
    record(0x1C, heap)
    record(0x2C, Data())

    var file = Data("JAVA PROFILE 1.0.2".utf8)
    file.append(0)
    u4(8, into: &file)
    u8(1_763_000_000_000, into: &file)
    file.append(records)
    return file
}

@MainActor
private func waitUntil(_ condition: () -> Bool, seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(condition(), "timed out", file: file, line: line)
}

@MainActor
final class IDEHeapDumpSessionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("heap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func dump() throws -> URL {
        let url = directory.appendingPathComponent("tiny.hprof")
        try tinyHeapDump().write(to: url)
        return url
    }

    func testReadsAndShowsTheHistogram() async throws {
        let session = IDEHeapDumpSession(url: try dump(), title: "tiny.hprof")
        session.load()
        try await waitUntil { session.phase == .ready }
        let overview = try XCTUnwrap(session.overview)
        XCTAssertEqual(overview.instanceCount, 4)
        XCTAssertEqual(overview.primitiveArrayCount, 1)
        XCTAssertEqual(overview.classCount, 3)
        XCTAssertEqual(overview.threadCount, 1)
        // Largest first: String (3 × 24), then the three class mirrors, byte[16] (32), Cache (16).
        XCTAssertEqual(session.visibleRows.first?.name, "java.lang.String")
        XCTAssertEqual(session.visibleRows.first?.shallowBytes, 72)

        session.filterText = "acme"
        XCTAssertEqual(session.visibleRows.map(\.name), ["com.acme.Cache"])

        session.filterText = ""
        session.grouping = .byPackage
        XCTAssertEqual(Set(session.visibleRows.map(\.name)), ["java.lang", "com.acme", "(primitive arrays)"])
        XCTAssertTrue(session.visibleRows.allSatisfy { $0.kind == .package })

        session.grouping = .byClass
        session.sortOrder = [KeyPathComparator(\.count, order: .reverse)]
        XCTAssertEqual(session.visibleRows.first?.count, 3, "three Strings, or the three class mirrors")
        XCTAssertEqual(session.visibleRows.last?.count, 1)

        // A wider layout makes every String bigger: 16 + 4 + 8 = 28 → 32.
        session.sortOrder = [KeyPathComparator(\.shallowBytes, order: .reverse)]
        session.layoutOverride = .uncompressed
        XCTAssertEqual(session.visibleRows.first { $0.name == "java.lang.String" }?.shallowBytes, 96)
        session.layoutOverride = nil
        XCTAssertEqual(session.visibleRows.first { $0.name == "java.lang.String" }?.shallowBytes, 72)

        session.mode = .summary
        session.showInHistogram("com.acme.Cache")
        XCTAssertEqual(session.mode, .histogram)
        XCTAssertEqual(session.visibleRows.map(\.name), ["com.acme.Cache"])
    }

    func testAFileThatIsNotADumpFailsWithASentence() async throws {
        let url = directory.appendingPathComponent("notes.hprof")
        try "not a heap dump\n".write(to: url, atomically: true, encoding: .utf8)
        let session = IDEHeapDumpSession(url: url, title: "notes.hprof")
        session.load()
        try await waitUntil { if case .failed = session.phase { true } else { false } }
        XCTAssertEqual(session.phase, .failed(HprofError.notAHeapDump.description))
    }

    func testCancelStopsTheReadItself() async throws {
        let session = IDEHeapDumpSession(url: try dump(), title: "slow")
        let observed = CancellationFlag()
        session.reader = { _, _ in
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                observed.set()
                throw error
            }
            throw HprofError.notAHeapDump
        }
        session.load()
        if case .reading = session.phase {} else { XCTFail("reading") }
        session.cancel()
        XCTAssertEqual(session.phase, .idle)
        try await waitUntil { observed.isSet }
    }

    func testAReloadDropsTheOlderResult() async throws {
        let session = IDEHeapDumpSession(url: try dump(), title: "tiny")
        let real = session.reader
        // `load()` takes the reader it starts with, so the first read is the slow failing one.
        session.reader = { _, _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            throw HprofError.notAHeapDump
        }
        session.load()
        session.reader = real
        session.load()
        try await waitUntil { session.phase == .ready }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(session.phase, .ready, "the first read's late failure is dropped")
    }

    func testSourceClassNames() {
        func row(_ name: String, _ kind: HeapClassRow.Kind) -> HeapClassRow {
            HeapClassRow(id: 0, name: name, kind: kind, count: 1, shallowBytes: 8)
        }
        XCTAssertEqual(IDEHeapDumpSession.sourceClassName(of: row("a.b.Foo$Bar", .instance)), "a.b.Foo$Bar")
        XCTAssertEqual(IDEHeapDumpSession.sourceClassName(of: row("a.b.Foo[][]", .objectArray)), "a.b.Foo")
        XCTAssertNil(IDEHeapDumpSession.sourceClassName(of: row("int[][]", .objectArray)))
        XCTAssertNil(IDEHeapDumpSession.sourceClassName(of: row("byte[]", .primitiveArray)))
        XCTAssertNil(IDEHeapDumpSession.sourceClassName(of: row("java.lang.Class", .classObject)))
        XCTAssertNil(IDEHeapDumpSession.sourceClassName(of: row("a.b", .package)))
    }
}

@MainActor
final class IDEHeapDumpRoutingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("heap-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func heapDocuments(_ workspace: IDEWorkspace) -> [WorkbenchDocument] {
        workspace.workbench.allDocuments().filter { $0.contentKind == .heapDump }
    }

    func testADumpOpensInTheAnalyzerByItsBytesAndASecondOpenReusesTheTab() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        // Renamed: found by its magic, not its name.
        let url = directory.appendingPathComponent("java_pid42.bin")
        try tinyHeapDump().write(to: url)

        await workspace.openDocument(from: url)
        XCTAssertEqual(heapDocuments(workspace).count, 1)
        let document = try XCTUnwrap(heapDocuments(workspace).first)
        XCTAssertEqual(document.displayName, "java_pid42.bin")
        XCTAssertEqual(workspace.workbench.activePane.selectedDocument?.id, document.id)
        let session = try XCTUnwrap(workspace.heapDumpSessionStore.session(for: document.id))
        try await waitUntil { session.phase == .ready }

        await workspace.openDocument(from: url)
        XCTAssertEqual(heapDocuments(workspace).count, 1, "the same dump reuses its tab")

        workspace.closeTab(document.id)
        XCTAssertTrue(heapDocuments(workspace).isEmpty)
        XCTAssertTrue(workspace.heapDumpSessionStore.sessions.isEmpty, "closing frees the session")
    }

    func testOpenAsHexBypassesTheAnalyzerAndATextFileNamedHprofStaysText() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let dump = directory.appendingPathComponent("heap.hprof")
        try tinyHeapDump().write(to: dump)
        await workspace.openDocument(from: dump, asHex: true)
        XCTAssertTrue(heapDocuments(workspace).isEmpty)
        XCTAssertEqual(workspace.workbench.activePane.selectedDocument?.contentKind, .binary)

        let notes = directory.appendingPathComponent("notes.hprof")
        try "how to read a heap dump\n".write(to: notes, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: notes)
        XCTAssertTrue(heapDocuments(workspace).isEmpty)
        XCTAssertEqual(workspace.workbench.activePane.selectedDocument?.contentKind, .text)
    }

    func testReopenAsHexTurnsTheTabIntoBytes() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let url = directory.appendingPathComponent("heap.hprof")
        try tinyHeapDump().write(to: url)
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(heapDocuments(workspace).first)
        let session = try XCTUnwrap(workspace.heapDumpSessionStore.session(for: document.id))

        workspace.reopenHeapDumpAsHex(sessionID: session.id)
        try await waitUntil { document.contentKind == .binary }
        XCTAssertTrue(workspace.heapDumpSessionStore.sessions.isEmpty)
        XCTAssertEqual(workspace.workbench.allDocuments().filter { $0.id == document.id }.count, 1, "same tab")
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Hosts the heap dump tab in a window so a crash or an empty render shows up in the run. Reads
/// `UMBRA_HPROF` when set (a real dump), the tiny one otherwise; `UMBRA_VIEW_SNAPSHOTS=<dir>` keeps
/// the images.
@MainActor
final class IDEHeapDumpViewsSmokeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("heap-views-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func render(_ session: IDEHeapDumpSession, name: String, size: NSSize = NSSize(width: 1100, height: 720)) throws -> Double {
        let host = NSHostingView(rootView: IDEHeapDumpView(session: session).preferredColorScheme(.dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["UMBRA_VIEW_SNAPSHOTS"],
           let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        var counts: [UInt32: Int] = [:]
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255)
                counts[key, default: 0] += 1
            }
        }
        let total = counts.values.reduce(0, +)
        guard total > 0, let common = counts.values.max() else { return 0 }
        return 1 - Double(common) / Double(total)
    }

    func testTheTabRendersReadingSummaryHistogramAndFailure() async throws {
        let url: URL
        if let path = ProcessInfo.processInfo.environment["UMBRA_HPROF"] {
            url = URL(fileURLWithPath: path)
        } else {
            url = directory.appendingPathComponent("tiny.hprof")
            try tinyHeapDump().write(to: url)
        }
        let session = IDEHeapDumpSession(url: url, title: url.lastPathComponent)
        let real = session.reader
        session.reader = { url, progress in
            progress(HeapDumpCensus.Progress(phase: .countingObjects, fraction: 0.4, bytesDone: 2_600_000_000, bytesTotal: 6_500_000_000))
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return try await real(url, progress)
        }
        session.load()
        try await waitUntil { if case .reading(let p) = session.phase { p.fraction > 0.3 } else { false } }
        XCTAssertGreaterThan(try render(session, name: "heap-1-reading"), 0.005)

        try await waitUntil({ session.phase == .ready }, seconds: 120)
        XCTAssertGreaterThan(try render(session, name: "heap-2-summary"), 0.05)

        session.mode = .histogram
        XCTAssertGreaterThan(try render(session, name: "heap-3-histogram"), 0.05)
        session.filterText = "HashMap"
        XCTAssertGreaterThan(try render(session, name: "heap-4-histogram-filtered"), 0.01)
        session.filterText = ""
        session.grouping = .byPackage
        XCTAssertGreaterThan(try render(session, name: "heap-5-packages"), 0.05)

        let notes = directory.appendingPathComponent("notes.hprof")
        try "not a dump\n".write(to: notes, atomically: true, encoding: .utf8)
        let failing = IDEHeapDumpSession(url: notes, title: "notes.hprof")
        failing.load()
        try await waitUntil { if case .failed = failing.phase { true } else { false } }
        XCTAssertGreaterThan(try render(failing, name: "heap-6-failed"), 0.001)
    }
}

@MainActor
final class IDEHeapObjectExplorerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("heap-objects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func readySession() async throws -> IDEHeapDumpSession {
        let url = directory.appendingPathComponent("tiny.hprof")
        if !FileManager.default.fileExists(atPath: url.path) { try tinyHeapDump().write(to: url) }
        let store = HeapIndexStore(root: directory.appendingPathComponent("indexes"))
        let session = IDEHeapDumpSession(url: url, title: "tiny.hprof", indexStore: store)
        session.load()
        try await waitUntil { session.phase == .ready }
        return session
    }

    private func isAbsent(_ state: IDEHeapObjectExplorer.IndexState) -> Bool {
        if case .absent = state { return true }
        return false
    }

    func testBuildThenBrowseInstancesFieldsAndReferrers() async throws {
        let session = try await readySession()
        let objects = session.objects
        try await waitUntil { self.isAbsent(objects.state) }
        if case .absent(let estimated, _) = objects.state { XCTAssertGreaterThan(estimated, 0) }

        objects.build()
        try await waitUntil { objects.state == .ready }
        XCTAssertEqual(objects.indexFacts?.references, 3, "the cache's entry, and String's and Cache's classes to Object")

        // A histogram row picked before or after the index: its instances, largest first.
        session.mode = .histogram
        let stringRow = try XCTUnwrap(session.visibleRows.first { $0.name == "java.lang.String" })
        session.selectedRowIDs = [stringRow.id]
        try await waitUntil { objects.instances.count == 3 }
        XCTAssertEqual(objects.groupName, "java.lang.String")
        XCTAssertEqual(objects.instanceTotal, 3)
        XCTAssertTrue(objects.instances.allSatisfy { $0.shallow == 24 })

        // The cache: its field points to the first String, which lists the cache as its referrer.
        let cacheRow = try XCTUnwrap(session.visibleRows.first { $0.name == "com.acme.Cache" })
        session.selectedRowIDs = [cacheRow.id]
        try await waitUntil { objects.instances.count == 1 }
        objects.selectedInstance = objects.instances[0].id
        try await waitUntil { !objects.isLoadingObject && !objects.fields.isEmpty }
        XCTAssertEqual(objects.inspectedTitle, "com.acme.Cache @ 0x200000")
        let entry = try XCTUnwrap(objects.fields.first)
        XCTAssertEqual(entry.name, "entry")
        let target = try XCTUnwrap(entry.target)
        XCTAssertTrue(entry.value.hasPrefix("java.lang.String @ 0x100000"), entry.value)

        objects.inspect(target)
        try await waitUntil { objects.inspectedTitle == "java.lang.String @ 0x100000" && objects.referrerTotal == 1 }
        XCTAssertEqual(objects.fields.map(\.name), ["hash", "value"])
        XCTAssertEqual(objects.referrers.first?.via, "entry")
        XCTAssertEqual(objects.referrers.first?.title, "com.acme.Cache @ 0x200000")
        XCTAssertEqual(objects.backStack.count, 1)

        objects.goBack()
        try await waitUntil { objects.inspectedTitle == "com.acme.Cache @ 0x200000" }
        XCTAssertEqual(objects.forwardStack.count, 1)
        objects.goForward()
        try await waitUntil { objects.inspectedTitle == "java.lang.String @ 0x100000" }

        // Grouping by package shows no instances.
        session.grouping = .byPackage
        XCTAssertNil(objects.group)
    }

    func testASecondTabFindsTheIndexAndDeleteForgetsIt() async throws {
        let first = try await readySession()
        try await waitUntil { self.isAbsent(first.objects.state) }
        first.objects.build()
        try await waitUntil { first.objects.state == .ready }

        let second = try await readySession()
        try await waitUntil { second.objects.state == .ready }

        second.objects.deleteIndex()
        XCTAssertTrue(isAbsent(second.objects.state))
        let third = try await readySession()
        try await waitUntil { self.isAbsent(third.objects.state) }
    }

    func testCancellingABuildLeavesNoIndex() async throws {
        let session = try await readySession()
        try await waitUntil { self.isAbsent(session.objects.state) }
        session.objects.build()
        session.objects.cancelBuild()
        try await waitUntil { self.isAbsent(session.objects.state) || session.objects.state == .ready }
        if isAbsent(session.objects.state) {
            let store = HeapIndexStore(root: directory.appendingPathComponent("indexes"))
            XCTAssertNil(store.openExisting(for: session.url))
        }
    }

    func testTheHistogramPaneRendersEachState() async throws {
        let session = try await readySession()
        session.mode = .histogram
        try await waitUntil { self.isAbsent(session.objects.state) }
        let host = NSHostingView(rootView: IDEHeapDumpView(session: session).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func snapshot(_ name: String) {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let folder = ProcessInfo.processInfo.environment["UMBRA_VIEW_SNAPSHOTS"],
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        snapshot("heap-objects-1-absent")
        session.objects.build()
        try await waitUntil { session.objects.state == .ready }
        let cache = try XCTUnwrap(session.visibleRows.first { $0.name == "com.acme.Cache" })
        session.selectedRowIDs = [cache.id]
        try await waitUntil { session.objects.instances.count == 1 }
        session.objects.selectedInstance = session.objects.instances[0].id
        try await waitUntil { !session.objects.isLoadingObject && !session.objects.fields.isEmpty }
        snapshot("heap-objects-2-inspector")
        session.objects.inspectorTab = .referrers
        if let target = session.objects.fields.first?.target { session.objects.inspect(target) }
        try await waitUntil { session.objects.referrerTotal == 1 }
        snapshot("heap-objects-3-referrers")
        session.mode = .summary
        snapshot("heap-objects-4-summary")
    }
}

/// The object pane on a real dump: `UMBRA_HPROF=<file>` and `UMBRA_HEAP_INDEX_ROOT=<dir>` holding
/// an index built for it (`PerfHarness heap-dump-index <file> --into <dir> --keep`, release, since
/// a debug build of a large index takes minutes). `UMBRA_VIEW_SNAPSHOTS=<dir>` keeps the images.
@MainActor
final class IDEHeapObjectsRealDumpTests: XCTestCase {
    func testBrowsingARealDump() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["UMBRA_HPROF"], let root = environment["UMBRA_HEAP_INDEX_ROOT"] else {
            throw XCTSkip("Set UMBRA_HPROF and UMBRA_HEAP_INDEX_ROOT to run")
        }
        let session = IDEHeapDumpSession(
            url: URL(fileURLWithPath: path), title: "dump", indexStore: HeapIndexStore(root: URL(fileURLWithPath: root))
        )
        session.load()
        try await waitUntil({ session.phase == .ready }, seconds: 120)
        try await waitUntil({ session.objects.state == .ready }, seconds: 30)
        session.mode = .histogram
        let host = NSHostingView(rootView: IDEHeapDumpView(session: session).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func snapshot(_ name: String) {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            guard let folder = environment["UMBRA_VIEW_SNAPSHOTS"],
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        let objects = session.objects
        let started = Date()
        let row = try XCTUnwrap(session.visibleRows.first { $0.name == "com.intellij.build.events.impl.OutputBuildEventImpl" }
            ?? session.visibleRows.first { $0.kind == .instance })
        session.selectedRowIDs = [row.id]
        try await waitUntil({ objects.instances.count == min(row.count, IDEHeapObjectExplorer.instanceLimit) }, seconds: 30)
        print("HEAPUI instances of \(row.name) in \(Date().timeIntervalSince(started)) s")
        objects.selectedInstance = objects.instances[0].id
        try await waitUntil { !objects.isLoadingObject && !objects.fields.isEmpty }
        snapshot("real-1-instances-fields")
        if let target = objects.fields.first(where: { $0.target != nil && $0.value.contains("String") })?.target
            ?? objects.fields.first(where: { $0.target != nil })?.target {
            objects.inspect(target)
            try await waitUntil { objects.backStack.count == 1 && !objects.isLoadingObject }
        }
        objects.inspectorTab = .referrers
        try await waitUntil { objects.referrerTotal > 0 }
        snapshot("real-2-referrers")

        let bytesRow = try XCTUnwrap(session.visibleRows.first { $0.name == "byte[]" })
        session.selectedRowIDs = [bytesRow.id]
        try await waitUntil({ objects.groupName == "byte[]" && !objects.instances.isEmpty }, seconds: 60)
        objects.inspectorTab = .fields
        objects.selectedInstance = objects.instances[0].id
        try await waitUntil { !objects.isLoadingObject && !objects.fields.isEmpty }
        snapshot("real-3-largest-byte-arrays")
        session.mode = .summary
        try await waitUntil({ objects.suspects != nil }, seconds: 120)
        snapshot("real-4-summary")

        // Dominators: the biggest holder, expanded, with its path to a root.
        session.mode = .dominators
        objects.loadDominatorsIfNeeded()
        try await waitUntil({ !objects.dominatorRows.isEmpty }, seconds: 30)
        objects.toggle(objects.dominatorRows[0])
        try await waitUntil({ objects.dominatorRows.count > 1 && objects.dominatorRows[1].depth == 1 }, seconds: 30)
        objects.selectedDominatorRow = objects.dominatorRows[0].id
        objects.inspectorTab = .path
        try await waitUntil { !objects.isLoadingObject && !objects.path.isEmpty }
        snapshot("real-5-dominators-path")
        var clock = Date()
        objects.inspectorTab = .retains
        try await waitUntil({ !objects.isLoadingRetainedSet && !objects.retainedSet.isEmpty }, seconds: 120)
        print("HEAPUI retains of the biggest holder in \(Date().timeIntervalSince(clock)) s, complete=\(objects.retainedSetComplete)")
        snapshot("real-6-retains")
        if let child = objects.dominatorRows.first(where: { $0.depth == 1 }) {
            objects.toggle(child)
            try await waitUntil({ objects.dominatorRows.contains { $0.depth == 2 } }, seconds: 30)
        }
        snapshot("real-7-dominators-deeper")

        clock = Date()
        objects.showMergedPaths(for: row)
        try await waitUntil({ objects.mergedPaths != nil }, seconds: 120)
        print("HEAPUI merged paths of \(row.name) in \(Date().timeIntervalSince(clock)) s")
        for line in objects.mergedPaths!.rows.prefix(8) {
            print("HEAPUI \(String(repeating: "  ", count: line.depth))\(line.title) ×\(line.count)")
        }
        objects.mergedPaths = nil

        // Reports: suspects and the three inspections.
        session.mode = .reports
        clock = Date()
        objects.loadInspectionsIfNeeded()
        try await waitUntil({ objects.duplicateStrings != nil && objects.zeroArrays != nil }, seconds: 300)
        print("HEAPUI inspections in \(Date().timeIntervalSince(clock)) s")
        if let suspect = objects.suspects?.first, let object = suspect.object {
            objects.inspectorTab = .path
            objects.inspect(object, startingOver: true)
            try await waitUntil { !objects.isLoadingObject }
        }
        snapshot("real-8-reports")

        // Threads: the one retaining most, its stack and a local.
        session.mode = .threads
        objects.loadThreadsIfNeeded()
        try await waitUntil({ objects.threads != nil }, seconds: 60)
        let busiest = try XCTUnwrap(objects.threads?.first { $0.frames.contains { !$0.locals.isEmpty } })
        objects.selectedThread = busiest.id
        try await waitUntil({ !objects.stackRows.isEmpty }, seconds: 30)
        if let local = objects.stackRows.first(where: { $0.local != nil }) {
            objects.inspectorTab = .fields
            objects.selectedStackRow = local.id
            try await waitUntil { !objects.isLoadingObject }
        }
        snapshot("real-9-threads")
    }
}


@MainActor
final class IDEHeapDominatorUITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("heap-dominators-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func indexedSession() async throws -> IDEHeapDumpSession {
        let url = directory.appendingPathComponent("tiny.hprof")
        try tinyHeapDump().write(to: url)
        let session = IDEHeapDumpSession(url: url, title: "tiny.hprof", indexStore: HeapIndexStore(root: directory.appendingPathComponent("indexes")))
        session.load()
        try await waitUntil { session.phase == .ready }
        try await waitUntil { if case .absent = session.objects.state { true } else { false } }
        session.objects.build()
        try await waitUntil { session.objects.state == .ready }
        return session
    }

    func testRetainedSizesReachTheHistogramAndInstances() async throws {
        let session = try await indexedSession()
        session.mode = .histogram
        try await waitUntil { session.visibleRows.contains { $0.retainedBytes != nil } }
        let rows = Dictionary(uniqueKeysWithValues: session.visibleRows.map { ($0.name, $0) })
        XCTAssertEqual(rows["com.acme.Cache"]?.retainedBytes, 16 + 24, "the cache keeps its entry")
        XCTAssertEqual(rows["java.lang.String"]?.retainedBytes, 24, "only the live string")
        XCTAssertEqual(rows["byte[]"]?.retainedBytes, 0, "garbage keeps nothing")
        session.sortOrder = [KeyPathComparator(\.retainedSortKey, order: .reverse)]
        XCTAssertEqual(session.visibleRows.first?.name, "com.acme.Cache")

        session.selectedRowIDs = [try XCTUnwrap(rows["java.lang.String"]).id]
        try await waitUntil { session.objects.instances.count == 3 }
        XCTAssertEqual(session.objects.instances.map(\.retained), [24, 0, 0], "the live one first")

        session.grouping = .byPackage
        XCTAssertTrue(session.visibleRows.allSatisfy { $0.retainedBytes == nil }, "no retained size for a package")
    }

    func testTheDominatorTreeExpandsAndSeparatesGarbage() async throws {
        let session = try await indexedSession()
        let objects = session.objects
        session.mode = .dominators
        objects.loadDominatorsIfNeeded()
        try await waitUntil { !objects.dominatorRows.isEmpty }
        XCTAssertEqual(objects.dominatorRows.map(\.title), ["com.acme.Cache", "class java.lang.String", "Unreachable objects"])
        XCTAssertEqual(objects.dominatorRows.first?.retained, 40)
        let unreachable = try XCTUnwrap(objects.dominatorRows.last)
        XCTAssertEqual(unreachable.shallow, 24 + 24 + 32 + 16, "two strings, the byte[] and the Cache class nobody holds")

        objects.toggle(objects.dominatorRows[0])
        try await waitUntil { objects.dominatorRows.count == 4 }
        XCTAssertEqual(objects.dominatorRows[1].title, "java.lang.String")
        XCTAssertEqual(objects.dominatorRows[1].depth, 1)

        objects.toggle(objects.dominatorRows.last!)
        try await waitUntil { objects.dominatorRows.count > 4 }
        let garbage = objects.dominatorRows.filter { if case .unreachableClass = $0.kind { true } else { false } }
        XCTAssertEqual(Set(garbage.map(\.title)), ["java.lang.String", "byte[]", "java.lang.Class"])
        XCTAssertEqual(garbage.first { $0.title == "java.lang.String" }?.detail, "2 objects")

        // Collapsing the cache removes its child and nothing else.
        let before = objects.dominatorRows.count
        objects.toggle(objects.dominatorRows[0])
        XCTAssertEqual(objects.dominatorRows.count, before - 1)
        XCTAssertEqual(objects.dominatorRows[1].title, "class java.lang.String")
        XCTAssertFalse(objects.dominatorRows[0].isExpanded)
    }

    func testShortTitlesKeepTheClassAndAddress() {
        XCTAssertEqual(IDEHeapInspectorView.shortTitle("com.acme.Outer$Inner @ 0x10"), "Outer$Inner @ 0x10")
        XCTAssertEqual(IDEHeapInspectorView.shortTitle("class java.lang.String @ 0x20"), "class String @ 0x20")
        XCTAssertEqual(IDEHeapInspectorView.shortTitle("byte[] @ 0x30"), "byte[] @ 0x30")
        XCTAssertEqual(IDEHeapInspectorView.shortTitle("java.lang.Object[] @ 0x40"), "Object[] @ 0x40")
    }

    func testPathRetainsAndMergedPaths() async throws {
        let session = try await indexedSession()
        let objects = session.objects
        session.mode = .histogram
        let cache = try XCTUnwrap(session.visibleRows.first { $0.name == "com.acme.Cache" })
        session.selectedRowIDs = [cache.id]
        try await waitUntil { objects.instances.count == 1 }
        objects.selectedInstance = objects.instances[0].id
        try await waitUntil { !objects.isLoadingObject && !objects.fields.isEmpty }
        XCTAssertTrue(objects.inspectedSummary.contains("40 bytes retained"), objects.inspectedSummary)
        objects.inspectorTab = .retains
        try await waitUntil { !objects.isLoadingRetainedSet && !objects.retainedSet.isEmpty }
        XCTAssertEqual(objects.retainedSet.map(\.name), ["java.lang.String", "com.acme.Cache"])
        XCTAssertTrue(objects.retainedSetComplete)

        let target = try XCTUnwrap(objects.fields.first?.target)
        objects.inspectorTab = .path
        objects.inspect(target)
        try await waitUntil { !objects.isLoadingObject && objects.path.count == 2 }
        XCTAssertEqual(objects.path.map(\.title), ["java.lang.String @ 0x100000", "com.acme.Cache @ 0x200000"])
        XCTAssertEqual(objects.path[1].via, "entry")
        XCTAssertEqual(objects.path[1].rootKinds, "Java frame")

        let string = try XCTUnwrap(session.visibleRows.first { $0.name == "java.lang.String" })
        objects.showMergedPaths(for: string)
        try await waitUntil { objects.mergedPaths != nil }
        let merged = try XCTUnwrap(objects.mergedPaths)
        XCTAssertEqual(merged.rows.map(\.title), ["com.acme.Cache @ 0x200000", "java.lang.String @ 0x100000"])
        XCTAssertEqual(merged.rows.map(\.depth), [0, 1])
        XCTAssertTrue(merged.rows[1].isTarget)
    }
}


@MainActor
final class IDEHeapWeakReachabilityTests: XCTestCase {
    func testOnlyWeaklyHeldObjectsAreTheirOwnBucketWithAWeakPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heap-weak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("weak.hprof")
        try tinyHeapDump(weak: true).write(to: url)
        let session = IDEHeapDumpSession(url: url, title: "weak.hprof", indexStore: HeapIndexStore(root: directory.appendingPathComponent("indexes")))
        session.load()
        try await waitUntil { session.phase == .ready }
        try await waitUntil { if case .absent = session.objects.state { true } else { false } }
        let objects = session.objects
        objects.build()
        try await waitUntil { objects.state == .ready }
        let index = try XCTUnwrap(objects.index)
        XCTAssertEqual(index.weaklyReachableCount, 1)

        session.mode = .dominators
        objects.loadDominatorsIfNeeded()
        try await waitUntil { !objects.dominatorRows.isEmpty }
        let weakRow = try XCTUnwrap(objects.dominatorRows.first { $0.kind == .weaklyReachable })
        XCTAssertEqual(weakRow.shallow, 24)
        XCTAssertEqual(objects.dominatorRows.last?.kind, .unreachable, "garbage stays last, apart")
        objects.toggle(weakRow)
        try await waitUntil { objects.dominatorRows.contains { if case .weaklyReachableClass = $0.kind { true } else { false } } }

        let weakString = try XCTUnwrap(index.number(ofID: 0x10_1000))
        objects.inspectorTab = .path
        objects.inspect(weakString, startingOver: true)
        try await waitUntil { !objects.isLoadingObject && objects.path.count == 2 }
        XCTAssertTrue(objects.inspectedSummary.contains("only weakly reachable"), objects.inspectedSummary)
        XCTAssertEqual(objects.path[1].title, "java.lang.ref.WeakReference @ 0x500000")
        XCTAssertEqual(objects.path[1].via, "referent")
        XCTAssertTrue(objects.path[1].isWeak)
        XCTAssertEqual(objects.path[1].rootKinds, "Java frame")

        let garbage = try XCTUnwrap(index.number(ofID: 0x10_2000))
        objects.inspect(garbage, startingOver: true)
        try await waitUntil { !objects.isLoadingObject }
        XCTAssertTrue(objects.path.isEmpty)
        XCTAssertTrue(objects.inspectedSummary.contains("unreachable (garbage)"), objects.inspectedSummary)
    }
}


@MainActor
final class IDEHeapReportsUITests: XCTestCase {
    func testSuspectsLoadWithTheIndexAndReportsAndThreadsFillIn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heap-reports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tiny.hprof")
        try tinyHeapDump(weak: true).write(to: url)
        let session = IDEHeapDumpSession(url: url, title: "tiny.hprof", indexStore: HeapIndexStore(root: directory.appendingPathComponent("indexes")))
        session.load()
        try await waitUntil { session.phase == .ready }
        try await waitUntil { if case .absent = session.objects.state { true } else { false } }
        let objects = session.objects
        objects.build()
        try await waitUntil { objects.state == .ready }
        try await waitUntil { objects.suspects != nil }
        XCTAssertEqual(objects.suspects?.first?.className, "com.acme.Cache", "the biggest holder of this tiny heap")

        session.mode = .reports
        objects.loadInspectionsIfNeeded()
        try await waitUntil { objects.duplicateStrings != nil && objects.wastedCollections != nil && objects.zeroArrays != nil }
        XCTAssertNil(objects.inspectionError)
        XCTAssertEqual(objects.duplicateStrings?.stringCount, 0, "the tiny dump's strings have no value arrays")

        session.mode = .threads
        objects.loadThreadsIfNeeded()
        try await waitUntil { objects.threads != nil }
        XCTAssertEqual(objects.threads?.count, 1)
        XCTAssertEqual(objects.threads?.first?.name, "Thread 1", "its object is not in the dump")
        objects.selectedThread = objects.threads?.first?.id
        XCTAssertTrue(objects.stackRows.isEmpty, "no trace was recorded")

        // Deleting the index forgets the reports with it.
        objects.deleteIndex()
        XCTAssertNil(objects.suspects)
        XCTAssertNil(objects.threads)
    }
}

@MainActor
final class IDEHeapDumpPhase5Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("heap-p5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func heapDocuments(_ workspace: IDEWorkspace) -> [WorkbenchDocument] {
        workspace.workbench.allDocuments().filter { $0.contentKind == .heapDump }
    }

    func testTheConsoleLinksTheDumpTheJVMPrints() {
        typealias C = IDERunConsoleView.Coordinator
        XCTAssertEqual(C.heapDumpPath(inLine: "Dumping heap to java_pid4242.hprof ...\n"), "java_pid4242.hprof")
        XCTAssertEqual(C.heapDumpPath(inLine: "Dumping heap to /Users/me/Library/Caches/dumps/java_pid1.hprof ..."), "/Users/me/Library/Caches/dumps/java_pid1.hprof")
        XCTAssertNil(C.heapDumpPath(inLine: "java.lang.OutOfMemoryError: Java heap space"))
        let text = "java.lang.OutOfMemoryError: Java heap space\nDumping heap to java_pid7.hprof ...\nHeap dump file created [123 bytes in 0.001 secs]\n"
        let attributed = NSMutableAttributedString(string: text)
        C.linkHeapDumps(in: text, into: attributed)
        let location = (text as NSString).range(of: "java_pid7.hprof").location
        let link = attributed.attribute(.link, at: location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.scheme, "umbra-heapdump")
        XCTAssertEqual(URLComponents(url: link!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "java_pid7.hprof")
        XCTAssertNil(attributed.attribute(.link, at: 0, effectiveRange: nil), "only the path is a link")
    }

    func testAPrintedRelativePathOpensFromTheRunsFolder() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        try tinyHeapDump().write(to: directory.appendingPathComponent("java_pid9.hprof"))
        workspace.openPrintedHeapDump("java_pid9.hprof", relativeTo: directory)
        XCTAssertEqual(heapDocuments(workspace).map(\.displayName), ["java_pid9.hprof"])
    }

    func testACompressedDumpDecompressesAndReplacesItsTab() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let name = "dump-\(UUID().uuidString)"
        let plain = directory.appendingPathComponent("\(name).hprof")
        try tinyHeapDump().write(to: plain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = [plain.path]   // replaces it with name.hprof.gz
        try process.run()
        process.waitUntilExit()
        let compressed = directory.appendingPathComponent("\(name).hprof.gz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressed.path))

        await workspace.openDocument(from: compressed)
        let tab = try XCTUnwrap(heapDocuments(workspace).first)
        let session = try XCTUnwrap(workspace.heapDumpSessionStore.session(for: tab.id))
        XCTAssertEqual(session.phase, .compressed)
        let target = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        session.decompressedFolder = target

        session.decompress()
        try await waitUntil { self.heapDocuments(workspace).map(\.displayName) == ["\(name).hprof"] }
        let decompressed = try XCTUnwrap(heapDocuments(workspace).first)
        XCTAssertEqual(decompressed.url?.standardizedFileURL, target.appendingPathComponent("\(name).hprof").standardizedFileURL)
        let opened = try XCTUnwrap(workspace.heapDumpSessionStore.session(for: decompressed.id))
        try await waitUntil { opened.phase == .ready }
        XCTAssertEqual(opened.overview?.instanceCount, 4)
    }

    func testCaptureHeapDumpRunsJcmdAndHandsTheFileOn() async throws {
        // A stand-in jcmd: copies a dump to the path it is given (the last argument).
        let source = directory.appendingPathComponent("source.hprof")
        try tinyHeapDump().write(to: source)
        let jcmd = directory.appendingPathComponent("jcmd")
        try "#!/bin/sh\nfor last; do :; done\necho \"$@\" > \"\(directory.path)/args\"\ncp \"\(source.path)\" \"$last\"\n"
            .write(to: jcmd, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jcmd.path)
        let monitor = IDEProfilerLiveMonitor(
            runID: "r", jcmd: jcmd, jps: nil, snapshotDirectory: directory.appendingPathComponent("snapshots"), knownProcessID: nil
        )
        monitor.installForTesting(samples: [], status: .attached(pid: 4242))
        let kept = directory.appendingPathComponent("kept", isDirectory: true)
        monitor.heapDumpDirectory = kept
        let captured = await monitor.captureHeapDump(allObjects: true)
        let file = try XCTUnwrap(captured)
        XCTAssertTrue(HprofDetector.isHeapDump(at: file))
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, kept.standardizedFileURL, "not in the pruned snapshots folder")
        XCTAssertTrue(file.lastPathComponent.hasPrefix("heap-") && file.lastPathComponent.hasSuffix("-pid4242-all.hprof"), file.lastPathComponent)
        let args = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertTrue(args.hasPrefix("4242 GC.heap_dump -all "), args)
        XCTAssertNil(monitor.notice)
    }
}
