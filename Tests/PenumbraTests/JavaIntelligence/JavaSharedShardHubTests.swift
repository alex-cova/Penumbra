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

    // MARK: - Jars

    private func jarTargets(_ names: [String], counters: [String: Counter], stampValue: Double = 1, delay: TimeInterval = 0.2) -> [(root: any JavaIndexableRoot, shardURL: URL)] {
        names.map { name in
            var slow = root(name, stampValue: stampValue, counter: counters[name] ?? Counter())
            slow.delay = delay
            return (root: slow as any JavaIndexableRoot, shardURL: directory.appendingPathComponent("\(name).idx"))
        }
    }

    private func reader(
        _ hub: JavaSharedShardHub,
        _ targets: [(root: any JavaIndexableRoot, shardURL: URL)],
        _ shard: URL
    ) async throws -> JavaIndexShardReader {
        let readers = await hub.readers(for: targets)
        return try XCTUnwrap(readers[shard])
    }

    private static func drain(_ stream: AsyncStream<JavaIndexScheduler.Progress>) async -> [JavaIndexScheduler.Progress] {
        var events: [JavaIndexScheduler.Progress] = []
        for await event in stream { events.append(event) }
        return events
    }

    /// Events that stand for one finished target: what a window's "n of N" counts.
    private static func completionCount(_ events: [JavaIndexScheduler.Progress]) -> Int {
        events.filter {
            switch $0 {
            case .rootSkipped, .rootFinished, .rootFailed: true
            case .rootStarted, .allFinished: false
            }
        }.count
    }

    func testTwoWindowsAskingForOverlappingJarsIndexEachJarOnce() async throws {
        let hub = makeHub()
        let counters = ["guava": Counter(), "junit": Counter(), "spring": Counter()]
        let first = jarTargets(["guava", "junit"], counters: counters)
        let second = jarTargets(["junit", "spring"], counters: counters)

        async let firstEvents = Self.drain(await hub.indexJars(first))
        async let secondEvents = Self.drain(await hub.indexJars(second))
        let (a, b) = await (firstEvents, secondEvents)

        for (name, counter) in counters {
            XCTAssertEqual(counter.current, 1, "\(name) was read once for both windows")
        }
        // Each window's counter reaches its own total, whoever did the work.
        XCTAssertEqual(Self.completionCount(a), 2)
        XCTAssertEqual(Self.completionCount(b), 2)
        XCTAssertEqual(a.filter { $0 == .allFinished }.count, 1)
        XCTAssertEqual(b.filter { $0 == .allFinished }.count, 1)
    }

    func testAWindowThatOnlyWaitsStillGetsAnEventPerJar() async throws {
        let hub = makeHub()
        let counters = ["guava": Counter()]
        let targets = jarTargets(["guava"], counters: counters, delay: 0.4)

        async let starter = Self.drain(await hub.indexJars(targets))
        try await Task.sleep(nanoseconds: 100_000_000)
        let waiter = await Self.drain(hub.indexJars(targets))
        _ = await starter

        XCTAssertEqual(counters["guava"]?.current, 1)
        XCTAssertFalse(waiter.contains { if case .rootStarted = $0 { true } else { false } }, "only the starter reports the start")
        XCTAssertEqual(waiter, [.rootSkipped(id: "guava", reason: "indexed by another window"), .allFinished])
    }

    func testAJarWhoseReaderIsLoadedCostsNothingTheSecondTime() async throws {
        let hub = makeHub()
        let counters = ["guava": Counter()]
        let targets = jarTargets(["guava"], counters: counters, delay: 0)

        _ = await Self.drain(hub.indexJars(targets))
        // A window holds the reader while the other one syncs.
        let held = try await reader(hub, targets, targets[0].shardURL)
        let events = await Self.drain(hub.indexJars(targets))

        XCTAssertEqual(counters["guava"]?.current, 1)
        XCTAssertEqual(events, [.rootSkipped(id: "guava", reason: "up to date"), .allFinished])
        withExtendedLifetime(held) {}
    }

    func testAJarWhoseShardIsCurrentOnDiskIsNotReadAgainEvenWithNoReaderLoaded() async throws {
        let hub = makeHub()
        let counters = ["guava": Counter()]
        let targets = jarTargets(["guava"], counters: counters, delay: 0)

        _ = await Self.drain(hub.indexJars(targets))
        let events = await Self.drain(hub.indexJars(targets))

        XCTAssertEqual(counters["guava"]?.current, 1, "the scheduler's stamp check found the shard current")
        XCTAssertEqual(Self.completionCount(events), 1)
    }

    func testReadersForASharedJarAreTheSameObject() async throws {
        let hub = makeHub()
        let targets = jarTargets(["guava"], counters: [:], delay: 0)
        _ = await Self.drain(hub.indexJars(targets))

        let first = await hub.readers(for: targets)
        let second = await hub.readers(for: targets)

        let a = try XCTUnwrap(first[targets[0].shardURL])
        let b = try XCTUnwrap(second[targets[0].shardURL])
        XCTAssertTrue(a === b)
    }

    func testAChangedJarIsIndexedAgainAndItsReaderReplaced() async throws {
        let hub = makeHub()
        let counters = ["guava": Counter()]
        let old = jarTargets(["guava"], counters: counters, stampValue: 1, delay: 0)
        _ = await Self.drain(hub.indexJars(old))
        let oldReader = try await reader(hub, old, old[0].shardURL)

        let changed = jarTargets(["guava"], counters: counters, stampValue: 2, delay: 0)
        let events = await Self.drain(hub.indexJars(changed))
        let newReader = try await reader(hub, changed, changed[0].shardURL)

        XCTAssertEqual(counters["guava"]?.current, 2)
        XCTAssertTrue(events.contains(.rootFinished(id: "guava", classCount: 1)))
        XCTAssertFalse(oldReader === newReader)
        XCTAssertEqual(newReader.stamp, JavaStamp(size: 10, modificationDate: 2))
    }

    func testInvalidateMakesTheNextRequestParseTheFile() async throws {
        let hub = makeHub()
        let targets = jarTargets(["guava"], counters: [:], delay: 0)
        _ = await Self.drain(hub.indexJars(targets))
        let before = try await reader(hub, targets, targets[0].shardURL)

        await hub.invalidate(targets[0].shardURL)
        let after = try await reader(hub, targets, targets[0].shardURL)

        XCTAssertFalse(before === after)
    }

    func testAStarterThatStopsListeningDoesNotCancelTheRun() async throws {
        let hub = makeHub()
        let counters = ["guava": Counter()]
        let targets = jarTargets(["guava"], counters: counters, delay: 0.3)

        // The window that started the run leaves after the first event.
        var stream = await hub.indexJars(targets).makeAsyncIterator()
        _ = await stream.next()
        let waiter = await Self.drain(hub.indexJars(targets))

        XCTAssertEqual(counters["guava"]?.current, 1)
        XCTAssertEqual(Self.completionCount(waiter), 1)
        let readers = await hub.readers(for: targets)
        XCTAssertNotNil(readers[targets[0].shardURL])
    }

    func testAJarWithNoShardIsAbsentFromTheReaders() async throws {
        let hub = makeHub()
        let targets = jarTargets(["never-indexed"], counters: [:])

        let readers = await hub.readers(for: targets)

        XCTAssertTrue(readers.isEmpty)
    }

    // MARK: - Retention

    private func writeShard(named name: String, classCount: Int, stamp: JavaStamp = JavaStamp(size: 0, modificationDate: 0)) throws -> URL {
        let url = directory.appendingPathComponent("\(name).idx")
        let stubs = (0..<classCount).map { index in
            JavaClassStub(
                binaryName: "\(name).C\(index)", qualifiedName: "\(name).C\(index)", simpleName: "C\(index)",
                packageName: name, kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test")
            )
        }
        try JavaIndexShardWriter().write(stubs, stamp: stamp, to: url)
        return url
    }

    private func jar(_ path: String, shard: URL) -> (root: any JavaIndexableRoot, shardURL: URL) {
        (root: JarRoot(jarURL: URL(fileURLWithPath: path)), shardURL: shard)
    }

    private let releasePath = "/Users/dev/.gradle/caches/modules-2/files-2.1/com.google.guava/guava/33.0.0-jre/abc/guava-33.0.0-jre.jar"
    private let snapshotPath = "/Users/dev/.gradle/caches/modules-2/files-2.1/com.acme/lib/1.0-SNAPSHOT/abc/lib-1.0-SNAPSHOT.jar"

    func testAReleaseJarsReaderSurvivesItsLastUserAndASnapshotsDoesNot() async throws {
        let hub = makeHub()
        let releaseShard = try writeShard(named: "guava", classCount: 3)
        let snapshotShard = try writeShard(named: "lib", classCount: 3)
        weak var releaseReader: JavaIndexShardReader?
        weak var snapshotReader: JavaIndexShardReader?

        do {
            let readers = await hub.readers(for: [
                jar(releasePath, shard: releaseShard),
                jar(snapshotPath, shard: snapshotShard)
            ])
            releaseReader = readers[releaseShard]
            snapshotReader = readers[snapshotShard]
            XCTAssertNotNil(releaseReader)
            XCTAssertNotNil(snapshotReader)
        }

        XCTAssertNotNil(releaseReader, "a release jar's reader is kept for the next open")
        XCTAssertNil(snapshotReader, "a snapshot's reader lives only while someone uses it")
        let retained = await hub.isRetained(releaseShard)
        XCTAssertTrue(retained)
        let snapshotRetained = await hub.isRetained(snapshotShard)
        XCTAssertFalse(snapshotRetained)
    }

    func testASnapshotsReaderIsSharedWhileSomeoneHoldsIt() async throws {
        let hub = makeHub()
        let shard = try writeShard(named: "lib", classCount: 3)
        let target = jar(snapshotPath, shard: shard)

        let held = try await reader(hub, [target], shard)
        let again = try await reader(hub, [target], shard)

        XCTAssertTrue(held === again)
    }

    func testARewrittenShardIsNeverServedFromTheCache() async throws {
        let hub = makeHub()
        let shard = try writeShard(named: "guava", classCount: 3, stamp: JavaStamp(size: 1, modificationDate: 1))
        let target = jar(releasePath, shard: shard)
        let old = try await reader(hub, [target], shard)

        // Another window (or process) re-indexed the jar.
        _ = try writeShard(named: "guava", classCount: 5, stamp: JavaStamp(size: 2, modificationDate: 2))
        let fresh = try await reader(hub, [target], shard)

        XCTAssertFalse(old === fresh)
        XCTAssertEqual(fresh.allQualifiedNames.count, 5)
    }

    func testRetainedReadersStayWithinTheirBudgetAndDropTheLeastRecentlyUsed() async throws {
        let hub = JavaSharedShardHub(paths: JavaIndexPaths(root: directory), retainedNameBudget: 25)
        let shards = try (0..<4).map { try writeShard(named: "jar\($0)", classCount: 10) }
        let paths = (0..<4).map { "/Users/dev/.m2/repository/g/a\($0)/1.0/a\($0)-1.0.jar" }

        for index in 0..<3 {
            _ = await hub.readers(for: [jar(paths[index], shard: shards[index])])
        }
        // 3 x 10 names exceed 25: the oldest went.
        var retained = await hub.retainedReaderCount
        XCTAssertEqual(retained, 2)
        let oldestKept = await hub.isRetained(shards[0])
        XCTAssertFalse(oldestKept)

        // Using jar1 again makes jar2 the least recently used.
        _ = await hub.readers(for: [jar(paths[1], shard: shards[1])])
        _ = await hub.readers(for: [jar(paths[3], shard: shards[3])])
        retained = await hub.retainedReaderCount
        XCTAssertEqual(retained, 2)
        let jar1Kept = await hub.isRetained(shards[1])
        let jar2Kept = await hub.isRetained(shards[2])
        let jar3Kept = await hub.isRetained(shards[3])
        XCTAssertTrue(jar1Kept)
        XCTAssertFalse(jar2Kept)
        XCTAssertTrue(jar3Kept)
    }

    func testAJarLargerThanTheWholeBudgetIsNotRetained() async throws {
        let hub = JavaSharedShardHub(paths: JavaIndexPaths(root: directory), retainedNameBudget: 5)
        let small = try writeShard(named: "small", classCount: 3)
        let huge = try writeShard(named: "huge", classCount: 50)

        _ = await hub.readers(for: [jar("/x/.m2/repository/s/s/1/s-1.jar", shard: small)])
        _ = await hub.readers(for: [jar("/x/.m2/repository/h/h/1/h-1.jar", shard: huge)])

        let smallKept = await hub.isRetained(small)
        let hugeKept = await hub.isRetained(huge)
        XCTAssertTrue(smallKept, "one huge jar does not evict the rest")
        XCTAssertFalse(hugeKept)
    }

    func testTrimmingMemoryDropsRetainedReadersButNotOnesInUse() async throws {
        let hub = makeHub()
        let shard = try writeShard(named: "guava", classCount: 3)
        let target = jar(releasePath, shard: shard)
        let inUse = try await reader(hub, [target], shard)

        await hub.trimMemory()

        let retained = await hub.retainedReaderCount
        XCTAssertEqual(retained, 0)
        let again = try await reader(hub, [target], shard)
        XCTAssertTrue(inUse === again, "a reader a window holds is still shared")
    }
}

