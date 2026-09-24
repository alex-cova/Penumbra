import XCTest
@testable import JavaIntelligence

final class JavaNameIndexTests: XCTestCase {
    private var dir: URL!
    private var src: URL!
    private var index: JavaNameIndex!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        index = JavaNameIndex(paths: JavaIndexPaths(root: dir.appendingPathComponent("cache")))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func write(_ name: String, _ text: String, mtime: TimeInterval? = nil) throws -> URL {
        let url = src.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: url.path)
        }
        return url
    }

    private func build() async -> [JavaIndexScheduler.Progress] {
        var events: [JavaIndexScheduler.Progress] = []
        for await event in await index.build(roots: [src]) { events.append(event) }
        return events
    }

    private func names(_ identifier: String) async -> [String] {
        await index.candidateFiles(containing: identifier, in: [src]).map(\.lastPathComponent)
    }

    func testBuildAndQuery() async throws {
        try write("A.java", "class A { Widget w; }")
        try write("pkg/B.java", "class B { // Widget\n String s = \"Widget\"; }")
        try write("C.java", "class C { void widget() {} }")
        let events = await build()
        XCTAssertTrue(events.contains(.allFinished))
        let name = await names("Widget")
        XCTAssertEqual(name, ["A.java"])
        let widget = await names("widget")
        XCTAssertEqual(widget, ["C.java"])
        let missing = await names("Nope")
        XCTAssertEqual(missing, [])
    }

    func testSecondBuildIsSkippedAndShardReloadsInFreshIndex() async throws {
        try write("A.java", "class A { Widget w; }")
        _ = await build()
        let events = await build()
        XCTAssertTrue(events.contains { if case .rootSkipped = $0 { return true } else { return false } })

        let fresh = JavaNameIndex(paths: JavaIndexPaths(root: dir.appendingPathComponent("cache")))
        let files = await fresh.candidateFiles(containing: "Widget", in: [src])
        XCTAssertEqual(files.map(\.lastPathComponent), ["A.java"])
    }

    func testChangedStampReindexesOnlyThatFile() async throws {
        let a = try write("A.java", "class A { Old o; }", mtime: 1_000_000)
        try write("B.java", "class B { Old o; }", mtime: 1_000_000)
        _ = await build()

        // Same size, new mtime: the stamp alone must trigger the re-read.
        try "class A { New o; }".write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: a.path)
        let events = await build()
        XCTAssertTrue(events.contains { if case .rootFinished = $0 { return true } else { return false } })

        let old = await names("Old")
        let new = await names("New")
        XCTAssertEqual(old, ["B.java"])
        XCTAssertEqual(new, ["A.java"])
    }

    func testFilesChangedUpdatesIncrementally() async throws {
        let a = try write("A.java", "class A { Old o; }")
        _ = await build()

        try "class A { Fresh o; }".write(to: a, atomically: true, encoding: .utf8)
        let created = try write("Sub/D.java", "class D { Fresh f; }")
        let affected = await index.filesChanged([a, created])
        XCTAssertEqual(affected.map(\.path), [src.path])
        let fresh = await names("Fresh")
        let old = await names("Old")
        XCTAssertEqual(fresh, ["A.java", "D.java"])
        XCTAssertEqual(old, [])
    }

    func testRemovedFileDisappears() async throws {
        let a = try write("A.java", "class A { Gone g; }")
        try write("B.java", "class B { Gone g; }")
        _ = await build()

        try FileManager.default.removeItem(at: a)
        await index.filesChanged([a])
        let after = await names("Gone")
        XCTAssertEqual(after, ["B.java"])

        // A rebuild (no incremental hint) notices removals too.
        let b = src.appendingPathComponent("B.java")
        try FileManager.default.removeItem(at: b)
        _ = await build()
        let none = await names("Gone")
        XCTAssertEqual(none, [])
        let count = await index.indexedFileCount(in: src)
        XCTAssertEqual(count, 0)
    }

    func testRemovedDirectoryTriggersRescan() async throws {
        try write("Sub/D.java", "class D { Deep d; }")
        _ = await build()
        try FileManager.default.removeItem(at: src.appendingPathComponent("Sub"))
        await index.filesChanged([src.appendingPathComponent("Sub")])
        let after = await names("Deep")
        XCTAssertEqual(after, [])
    }

    func testOverlayReplacesDiskContents() async throws {
        let a = try write("A.java", "class A { OnDisk x; }")
        try write("B.java", "class B { Shared s; }")
        _ = await build()

        await index.setOverlay(a, text: "class A { InBuffer x; Shared s; }")
        let onDisk = await names("OnDisk")
        let inBuffer = await names("InBuffer")
        let shared = await names("Shared")
        XCTAssertEqual(onDisk, [])
        XCTAssertEqual(inBuffer, ["A.java"])
        XCTAssertEqual(shared, ["A.java", "B.java"])

        await index.removeOverlay(a)
        let restored = await names("OnDisk")
        XCTAssertEqual(restored, ["A.java"])
    }

    func testOverlayForUnsavedFileUnderRoot() async throws {
        _ = await build()
        let unsaved = src.appendingPathComponent("New.java")
        await index.setOverlay(unsaved, text: "class New { Thing t; }")
        let found = await index.candidateFiles(containing: "Thing", in: [src])
        XCTAssertEqual(found, [unsaved])
    }

    func testShardRoundTrip() throws {
        let shard = dir.appendingPathComponent("x/refs.idx")
        let entries = [
            JavaNameIndexEntry(relativePath: "a/A.java", stamp: JavaStamp(size: 3, modificationDate: 4.5), identifiers: ["A", "b"]),
            JavaNameIndexEntry(relativePath: "B.java", stamp: JavaStamp(size: 7, modificationDate: 8), identifiers: ["b"])
        ]
        try JavaNameIndexShardWriter().write(entries, to: shard)
        let reader = try JavaNameIndexShardReader(url: shard)
        XCTAssertEqual(reader.relativePaths(containing: "b").sorted(), ["B.java", "a/A.java"])
        XCTAssertEqual(reader.relativePaths(containing: "A"), ["a/A.java"])
        XCTAssertEqual(reader.allEntries(), entries)
        XCTAssertThrowsError(try JavaNameIndexShardReader(url: dir.appendingPathComponent("missing.idx")))
    }
}
