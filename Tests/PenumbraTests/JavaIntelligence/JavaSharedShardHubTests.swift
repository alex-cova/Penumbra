import XCTest
@testable import JavaIntelligence

/// The JDK's API stubs are the same for every window, so windows share one indexing run and one
/// parsed shard (`JavaSharedShardHub`).
final class JavaSharedShardHubTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// A root whose read takes a moment, so a second caller arrives while it is still being indexed.
    private struct SlowRoot: JavaIndexableRoot {
        let id: String
        let stamp: JavaStamp
        let counter: Counter
        var delay: TimeInterval = 0.3

        func readStubs() throws -> [JavaClassStub] {
            counter.increment()
            Thread.sleep(forTimeInterval: delay)
            return [JavaClassStub(
                binaryName: "java.lang.Object", qualifiedName: "java.lang.Object", simpleName: "Object",
                packageName: "java.lang", kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("java.base")
            )]
        }
    }

    private func makeHub() -> JavaSharedShardHub {
        JavaSharedShardHub(paths: JavaIndexPaths(root: directory))
    }

    private func root(_ id: String, stampValue: Double = 1, counter: Counter) -> SlowRoot {
        SlowRoot(id: id, stamp: JavaStamp(size: 10, modificationDate: stampValue), counter: counter)
    }

    func testCallersAskingAtTheSameTimeShareOneIndexingRun() async throws {
        let hub = makeHub()
        let counter = Counter()
        let shard = directory.appendingPathComponent("jdk.idx")
        let jdk = root("jdk", counter: counter)

        async let first = hub.shard(for: jdk, at: shard)
        async let second = hub.shard(for: jdk, at: shard)
        let (a, b) = await (first, second)

        XCTAssertEqual(counter.current, 1, "the JDK was indexed once for both callers")
        let readerA = try XCTUnwrap(a)
        let readerB = try XCTUnwrap(b)
        XCTAssertTrue(readerA === readerB, "both callers got the same parsed shard")
        let runs = await hub.indexRunCount
        XCTAssertEqual(runs, 1)
    }

    func testAnUpToDateShardIsReusedWithoutIndexingAgain() async throws {
        let hub = makeHub()
        let counter = Counter()
        let shard = directory.appendingPathComponent("jdk.idx")
        let jdk = root("jdk", counter: counter)

        let first = await hub.shard(for: jdk, at: shard)
        let second = await hub.shard(for: jdk, at: shard)

        XCTAssertEqual(counter.current, 1)
        XCTAssertTrue(try XCTUnwrap(first) === XCTUnwrap(second))
    }

    func testAnotherHubFindsTheShardOnDiskAndDoesNotIndexAgain() async throws {
        let counter = Counter()
        let shard = directory.appendingPathComponent("jdk.idx")
        let jdk = root("jdk", counter: counter)
        _ = await makeHub().shard(for: jdk, at: shard)

        // A second process (or a relaunch) has no cached reader but finds the atomic file.
        let reader = await makeHub().shard(for: jdk, at: shard)

        XCTAssertEqual(counter.current, 1)
        XCTAssertEqual(reader?.allQualifiedNames, ["java.lang.Object"])
    }

    func testAChangedRootIsIndexedAgain() async throws {
        let hub = makeHub()
        let counter = Counter()
        let shard = directory.appendingPathComponent("jdk.idx")

        let old = await hub.shard(for: root("jdk", stampValue: 1, counter: counter), at: shard)
        let updated = await hub.shard(for: root("jdk", stampValue: 2, counter: counter), at: shard)

        XCTAssertEqual(counter.current, 2)
        XCTAssertFalse(try XCTUnwrap(old) === XCTUnwrap(updated))
        XCTAssertEqual(updated?.stamp.modificationDate, 2)
    }

    func testOnlyTheCallerThatStartedTheRunHearsItsProgress() async throws {
        let hub = makeHub()
        let counter = Counter()
        let shard = directory.appendingPathComponent("jdk.idx")
        let jdk = root("jdk", counter: counter)
        let starterEvents = Counter()
        let waiterEvents = Counter()

        async let starter = hub.shard(for: jdk, at: shard) { _ in starterEvents.increment() }
        // Give the starter a head start so the other caller joins its run.
        try await Task.sleep(nanoseconds: 100_000_000)
        async let waiter = hub.shard(for: jdk, at: shard) { _ in waiterEvents.increment() }
        _ = await (starter, waiter)

        XCTAssertGreaterThan(starterEvents.current, 0)
        XCTAssertEqual(waiterEvents.current, 0)
    }

    func testLeastRecentlyUsedReadersAreDropped() async throws {
        let hub = makeHub()
        let counter = Counter()
        for index in 0..<(JavaSharedShardHub.maxCachedReaders + 2) {
            var slow = root("jdk\(index)", counter: counter)
            slow.delay = 0
            _ = await hub.shard(for: slow, at: directory.appendingPathComponent("jdk\(index).idx"))
        }

        let cached = await hub.cachedReaderCount
        XCTAssertEqual(cached, JavaSharedShardHub.maxCachedReaders)
    }
}
