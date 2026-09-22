import XCTest
@testable import JavaIntelligence

final class JavaIndexSchedulerTests: XCTestCase {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A plain reference-type counter, safe to capture across the scheduler's concurrent reads
    /// (unlike a raw pointer into a local variable, which is only valid for one call's duration).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct FakeRoot: JavaIndexableRoot {
        let id: String
        let stamp: JavaStamp
        let stubs: [JavaClassStub]
        var readCount: Counter?

        func readStubs() throws -> [JavaClassStub] {
            readCount?.increment()
            return stubs
        }
    }

    private func stub(_ name: String) -> JavaClassStub {
        JavaClassStub(binaryName: name, qualifiedName: name, simpleName: name, packageName: "", kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test"))
    }

    func testIndexesRootAndWritesReadableShard() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shardURL = dir.appendingPathComponent("root.idx")

        let root = FakeRoot(id: "root1", stamp: JavaStamp(size: 1, modificationDate: 1), stubs: [stub("com.example.Foo")])
        let scheduler = JavaIndexScheduler(paths: JavaIndexPaths(root: dir))
        var events: [JavaIndexScheduler.Progress] = []
        for await event in await scheduler.index([(root: root, shardURL: shardURL)]) {
            events.append(event)
        }

        XCTAssertTrue(events.contains(.rootFinished(id: "root1", classCount: 1)))
        XCTAssertTrue(events.contains(.allFinished))
        let reader = try JavaIndexShardReader(url: shardURL)
        XCTAssertEqual(reader.allQualifiedNames, ["com.example.Foo"])
    }

    func testSkipsRootWhenShardStampAlreadyMatches() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shardURL = dir.appendingPathComponent("root.idx")
        let stamp = JavaStamp(size: 42, modificationDate: 42)

        let counter = Counter()
        let root = FakeRoot(id: "root1", stamp: stamp, stubs: [stub("com.example.Foo")], readCount: counter)

        let scheduler = JavaIndexScheduler(paths: JavaIndexPaths(root: dir))
        // First pass: no existing shard, so it indexes and writes one.
        for await _ in await scheduler.index([(root: root, shardURL: shardURL)]) {}
        XCTAssertEqual(counter.current, 1)

        // Second pass: the shard's stamp already matches, so readStubs() must not run again.
        var events: [JavaIndexScheduler.Progress] = []
        for await event in await scheduler.index([(root: root, shardURL: shardURL)]) {
            events.append(event)
        }
        XCTAssertEqual(counter.current, 1, "a matching stamp should skip re-reading the root")
        XCTAssertTrue(events.contains(.rootSkipped(id: "root1", reason: "up to date")))
    }

    func testReindexesWhenStampChanges() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shardURL = dir.appendingPathComponent("root.idx")

        let scheduler = JavaIndexScheduler(paths: JavaIndexPaths(root: dir))
        let firstRoot = FakeRoot(id: "root1", stamp: JavaStamp(size: 1, modificationDate: 1), stubs: [stub("com.example.Foo")])
        for await _ in await scheduler.index([(root: firstRoot, shardURL: shardURL)]) {}

        let secondRoot = FakeRoot(id: "root1", stamp: JavaStamp(size: 2, modificationDate: 2), stubs: [stub("com.example.Foo"), stub("com.example.Bar")])
        var events: [JavaIndexScheduler.Progress] = []
        for await event in await scheduler.index([(root: secondRoot, shardURL: shardURL)]) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.rootFinished(id: "root1", classCount: 2)))
        let reader = try JavaIndexShardReader(url: shardURL)
        XCTAssertEqual(Set(reader.allQualifiedNames), ["com.example.Foo", "com.example.Bar"])
    }

    func testMultipleRootsAllComplete() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let roots: [(root: any JavaIndexableRoot, shardURL: URL)] = (0..<8).map { i in
            let root = FakeRoot(id: "root\(i)", stamp: JavaStamp(size: Int64(i), modificationDate: Double(i)), stubs: [stub("com.example.Item\(i)")])
            return (root, dir.appendingPathComponent("root\(i).idx"))
        }
        let scheduler = JavaIndexScheduler(paths: JavaIndexPaths(root: dir), maxConcurrency: 3)
        var finishedIDs: Set<String> = []
        for await event in await scheduler.index(roots) {
            if case .rootFinished(let id, _) = event {
                finishedIDs.insert(id)
            }
        }
        XCTAssertEqual(finishedIDs, Set((0..<8).map { "root\($0)" }))
    }

    func testFailingRootReportsFailureWithoutStoppingOthers() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        struct ThrowingRoot: JavaIndexableRoot {
            let id = "bad"
            let stamp = JavaStamp(size: 0, modificationDate: 0)
            func readStubs() throws -> [JavaClassStub] { throw ZipArchiveError.notAZipFile }
        }
        let goodRoot = FakeRoot(id: "good", stamp: JavaStamp(size: 1, modificationDate: 1), stubs: [stub("com.example.Foo")])
        let scheduler = JavaIndexScheduler(paths: JavaIndexPaths(root: dir))
        var events: [JavaIndexScheduler.Progress] = []
        for await event in await scheduler.index([
            (root: ThrowingRoot(), shardURL: dir.appendingPathComponent("bad.idx")),
            (root: goodRoot, shardURL: dir.appendingPathComponent("good.idx"))
        ]) {
            events.append(event)
        }
        XCTAssertTrue(events.contains { if case .rootFailed(let id, _) = $0 { return id == "bad" } else { return false } })
        XCTAssertTrue(events.contains(.rootFinished(id: "good", classCount: 1)))
    }

    // MARK: - Real JDK end-to-end (opt-in)

    func testEndToEndIndexesRealJDKCtSym() async throws {
        guard let found = TestJDK.discovered,
              let installation = ReleaseFileParser.parse(found.home),
              installation.hasCtSym else {
            throw XCTSkip("No JDK with ct.sym found on this machine")
        }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = JavaIndexPaths(root: dir)
        let root = JDKCtSymRoot(installation: installation)
        let shardURL = paths.jdkShard(installation, kind: "ctsym")

        let scheduler = JavaIndexScheduler(paths: paths)
        var finished = false
        for await event in await scheduler.index([(root: root, shardURL: shardURL)]) {
            if case .rootFinished(_, let count) = event {
                finished = true
                XCTAssertGreaterThan(count, 1000)
            }
        }
        XCTAssertTrue(finished)

        let index = JavaIndex()
        let reader = try JavaIndexShardReader(url: shardURL)
        await index.setSources([.init(precedence: 3, reader: reader)])
        let string = await index.classStub(qualifiedName: "java.lang.String")
        XCTAssertNotNil(string)
        let matches = await index.classes(simpleNamePrefix: "ArrayL")
        XCTAssertTrue(matches.contains { $0.simpleName == "ArrayList" })
    }
}
