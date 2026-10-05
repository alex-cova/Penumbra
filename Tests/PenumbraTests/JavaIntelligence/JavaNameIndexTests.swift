import Darwin
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
        try write("B.java", "class B { Kept k; }")
        _ = await build()

        try "class A { Fresh o; }".write(to: a, atomically: true, encoding: .utf8)
        let created = try write("Sub/D.java", "class D { Fresh f; }")
        let affected = await index.filesChanged([a, created])
        XCTAssertEqual(affected.map(\.path), [src.path])
        let fresh = await names("Fresh")
        let old = await names("Old")
        let kept = await names("Kept")
        XCTAssertEqual(fresh, ["A.java", "D.java"])
        XCTAssertEqual(old, [])
        XCTAssertEqual(kept, ["B.java"])
    }

    func testRemovedFileDisappears() async throws {
        let a = try write("A.java", "class A { Gone g; }")
        try write("B.java", "class B { Gone g; }")
        _ = await build()

        try FileManager.default.removeItem(at: a)
        await index.filesChanged([a])
        let after = await names("Gone")
        XCTAssertEqual(after, ["B.java"])
        let remaining = await index.indexedFileCount(in: src)
        XCTAssertEqual(remaining, 1)

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

    func testStampScanMatchesTheURLWalk() throws {
        try write("A.java", "class A {}")
        try write("pkg/B.java", "class B {}")
        try write(".hidden.java", "class H {}")
        try write("build/Gen.java", "class Gen {}")
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("Link.java"), withDestinationURL: src.appendingPathComponent("A.java"))
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("linked-dir"), withDestinationURL: src.appendingPathComponent("pkg"))
        let scanned = try XCTUnwrap(JavaSourceStampScan.javaFiles(in: src))
        let walked = urlWalkStamps(src)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: scanned.map { ($0.relativePath, $0.stamp) }), walked)
    }

    func testRewriteReaderMatchesTheFile() throws {
        let shard = dir.appendingPathComponent("x/refs.idx")
        let original = [
            JavaNameIndexEntry(relativePath: "a/A.java", stamp: JavaStamp(size: 3, modificationDate: 4.5), identifiers: ["A", "Kept"]),
            JavaNameIndexEntry(relativePath: "B.java", stamp: JavaStamp(size: 7, modificationDate: 8), identifiers: ["Kept"])
        ]
        try JavaNameIndexShardWriter().write(original, to: shard)
        let reader = try JavaNameIndexShardReader(url: shard)
        let updated = JavaNameIndexEntry(
            relativePath: "a/A.java", stamp: JavaStamp(size: 9, modificationDate: 10), identifiers: ["A", "Fresh"]
        )
        let rewritten = try JavaNameIndexShardWriter().rewrite(from: reader, removing: [0], replacing: [updated], to: shard)
        let fromDisk = try JavaNameIndexShardReader(url: shard)
        XCTAssertEqual(rewritten.allEntries(), fromDisk.allEntries())
        XCTAssertEqual(rewritten.relativePaths(containing: "Kept").sorted(), fromDisk.relativePaths(containing: "Kept").sorted())
        XCTAssertEqual(rewritten.relativePaths(containing: "Fresh"), ["a/A.java"])
        XCTAssertEqual(fromDisk.relativePaths(containing: "Fresh"), ["a/A.java"])
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

    func testIncrementalUpdatesMatchAFullRebuild() async throws {
        let steps: [(String, String?)] = [
            ("A.java", "class A { Gamma a; }"),
            ("C.java", "class C { Gamma g; }"),
            ("B.java", nil),
            ("A.java", "class A { Delta a; }"),
            ("C.java", "class C { Gamma g; NewId n; }"),
            ("C.java", "class C { NewId n; }")
        ]
        try write("A.java", "class A { Alpha a; }", mtime: 1_000)
        try write("B.java", "class B { Beta b; }", mtime: 1_000)

        _ = await build()
        var when = 2_000.0
        for (name, text) in steps {
            let url = src.appendingPathComponent(name)
            if let text {
                try write(name, text, mtime: when)
            } else {
                try FileManager.default.removeItem(at: url)
            }
            when += 1
            await index.filesChanged([url])
        }
        let afterDelete = await index.indexedFileCount(in: src)
        XCTAssertEqual(afterDelete, 2)
        let incremental = try shardEntries(cache: dir.appendingPathComponent("cache"), root: src)

        let freshRoot = dir.appendingPathComponent("fresh-cache")
        let fresh = JavaNameIndex(paths: JavaIndexPaths(root: freshRoot))
        for await _ in await fresh.build(roots: [src]) {}
        let rebuilt = try shardEntries(cache: freshRoot, root: src)
        XCTAssertEqual(incremental, rebuilt)

        let replayRoot = dir.appendingPathComponent("replay-src")
        let replayCache = dir.appendingPathComponent("replay-cache")
        try FileManager.default.createDirectory(at: replayRoot, withIntermediateDirectories: true)
        func replayWrite(_ name: String, _ text: String, _ mtime: TimeInterval) throws {
            let url = replayRoot.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: url.path)
        }
        try replayWrite("A.java", "class A { Alpha a; }", 1_000)
        try replayWrite("B.java", "class B { Beta b; }", 1_000)
        let replay = JavaNameIndex(paths: JavaIndexPaths(root: replayCache))
        for await _ in await replay.build(roots: [replayRoot]) {}
        when = 2_000
        for (name, text) in steps {
            let url = replayRoot.appendingPathComponent(name)
            if let text {
                try replayWrite(name, text, when)
            } else {
                try FileManager.default.removeItem(at: url)
            }
            when += 1
            for await _ in await replay.build(roots: [replayRoot]) {}
        }
        let replayed = try shardEntries(cache: replayCache, root: replayRoot)
        XCTAssertEqual(replayed, rebuilt)
    }

    private func urlWalkStamps(_ root: URL) -> [String: JavaStamp] {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let resolved = JavaNameIndexTests.realPath(root.path)
        let resolvedPrefix = resolved.hasSuffix("/") ? resolved : resolved + "/"
        var walked: [String: JavaStamp] = [:]
        for url in SourceRoot(directory: root).javaFileURLs() {
            let path = url.path
            guard path.hasPrefix(resolvedPrefix) || path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(path.hasPrefix(prefix) ? prefix.count : resolvedPrefix.count))
            guard let stamp = JavaStamp(url: url) else { continue }
            walked[relative] = stamp
        }
        return walked
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func shardEntries(cache: URL, root: URL) throws -> [String: JavaNameIndexEntry] {
        let shard = JavaIndexPaths(root: cache).projectNameIndexShard(for: root)
        let reader = try JavaNameIndexShardReader(url: shard)
        return Dictionary(uniqueKeysWithValues: reader.allEntries().map { ($0.relativePath, $0) })
    }
}
