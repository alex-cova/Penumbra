import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// Unresolved-type and unresolved-import findings are claims that a class does not exist. They
/// are only made against an index that can prove it, and a finding made against an older set of
/// sources is never served after the sources changed.
final class JavaResolutionReadinessTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Fixtures

    private static let platform = [
        "package java.lang; public class Object { }",
        "package java.lang; public final class String { }",
        "package java.util; public interface List<E> { }",
        "package java.util; public interface Map<K, V> { }",
        "package java.util; public class ArrayList<E> implements List<E> { }",
        "package java.util.concurrent; public class CompletableFuture<T> { }",
        "package java.time; public final class LocalDate { }",
    ]

    private func shard(_ sources: [String]) throws -> JavaIndexShardReader {
        var stubs: [JavaClassStub] = []
        for (number, source) in sources.enumerated() {
            let file = scratch.appendingPathComponent("S\(UUID().uuidString)-\(number).java")
            try source.write(to: file, atomically: true, encoding: .utf8)
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: file).classes)
        }
        let url = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        return try JavaIndexShardReader(url: url)
    }

    private func jdk() throws -> JavaIndex.Source { .init(precedence: 3, reader: try shard(Self.platform)) }

    private func document(_ source: String, url: URL) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    private static let resolutionTest = """
    import java.util.List;
    import java.util.Map;
    import java.util.ArrayList;
    import java.util.concurrent.CompletableFuture;
    import java.time.LocalDate;

    public class ResolutionTest {
        private String name;
        private List<String> names;
        private Map<String, Object> values;
        private CompletableFuture<String> future;
        private LocalDate date;

        public void test() {
            Object value = new Object();
            ArrayList<String> items = new ArrayList<>();
        }
    }
    """

    private func service(_ index: JavaIndex) -> JavaInspectionService {
        JavaInspectionService(index: index, enabledRules: [.unresolvedType, .unresolvedImport], idleDelay: .milliseconds(1))
    }

    private func codes(_ diagnostics: [Diagnostic]) -> [String] {
        diagnostics.compactMap(\.code).sorted()
    }

    // MARK: - The stale-negative sequence

    /// Window opens, the file is inspected before the JDK shard is published, the JDK lands.
    /// The first pass must not claim `String` is missing, and nothing computed before the JDK
    /// arrived may be served after it.
    func testAPassBeforeTheJDKIsIndexedNeverOutlivesIt() async throws {
        let index = JavaIndex()
        let service = service(index)
        let doc = document(Self.resolutionTest, url: scratch.appendingPathComponent("ResolutionTest.java"))

        await service.analyzeNow(doc, force: true)
        let before = await service.diagnostics(for: doc)
        XCTAssertEqual(codes(before), [], "no JDK in the index: absence cannot be proven")

        await index.setSources([try jdk()])
        let fresh = await service.isFresh(doc)
        XCTAssertFalse(fresh, "a result computed against other sources is stale")
        await service.analyzeNow(doc)
        let after = await service.diagnostics(for: doc)
        XCTAssertEqual(codes(after), [])
    }

    /// The project's whole-tree shard often lands before a cold JDK. Project sources without the
    /// platform still cannot prove `String` is missing.
    func testProjectSourcesWithoutThePlatformArePending() async throws {
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try shard(["package app; public class Helper { }"]))])
        let canProve = await index.canProveAbsence
        XCTAssertFalse(canProve)
        let service = service(index)
        let doc = document("package app;\nclass T { String s; Helper h; Missing m; }", url: scratch.appendingPathComponent("T.java"))
        await service.analyzeNow(doc, force: true)
        let found = await service.diagnostics(for: doc)
        XCTAssertEqual(codes(found), [])
    }

    // MARK: - No false negatives

    /// Once the JDK is in, the sample resolves cleanly and a genuinely missing class and import
    /// are still reported.
    func testGenuinelyMissingClassesStillReportOnceAuthoritative() async throws {
        let index = JavaIndex()
        await index.setSources([try jdk()])
        let service = service(index)
        let clean = document(Self.resolutionTest, url: scratch.appendingPathComponent("ResolutionTest.java"))
        await service.analyzeNow(clean, force: true)
        let cleanFindings = await service.diagnostics(for: clean)
        XCTAssertEqual(codes(cleanFindings), [], "valid JDK types resolve")

        let broken = document("""
        import com.nowhere.Gizmo;
        class T { Widget w; java.util.List<String> xs; }
        """, url: scratch.appendingPathComponent("T.java"))
        await service.analyzeNow(broken, force: true)
        let found = await service.diagnostics(for: broken)
        XCTAssertEqual(found.map(\.message).sorted(), [
            "Cannot resolve import 'com.nowhere.Gizmo'",
            "Cannot resolve type 'Widget'",
        ])
    }

    // MARK: - Classpath completeness

    /// A Gradle project before its model: the dependency jars are unknown, so a dependency type is
    /// pending, not missing. With the model the jar resolves it; a class the jars don't have then
    /// reports.
    func testDependencyTypesWaitForTheClasspath() async throws {
        let index = JavaIndex()
        let jdk = try jdk()
        await index.setSources([jdk], classpathComplete: false)
        let service = service(index)
        let doc = document("""
        import jakarta.inject.Inject;
        class T { @Inject Inject marker; Gadget g; }
        """, url: scratch.appendingPathComponent("T.java"))
        await service.analyzeNow(doc, force: true)
        let pending = await service.diagnostics(for: doc)
        XCTAssertEqual(codes(pending), [], "no claims while the classpath is incomplete")

        let jar = JavaIndex.Source(precedence: 2, reader: try shard(["package jakarta.inject; public @interface Inject { }"]))
        await index.setSources([jdk, jar], classpathComplete: true)
        await service.analyzeNow(doc)
        let synced = await service.diagnostics(for: doc)
        XCTAssertEqual(synced.map(\.message), ["Cannot resolve type 'Gadget'"])
    }

    /// The same text is re-judged when only the completeness flag moves.
    func testCompletenessChangeAloneInvalidates() async throws {
        let index = JavaIndex()
        let jdk = try jdk()
        await index.setSources([jdk], classpathComplete: false)
        let before = await index.sourcesVersion
        await index.setSources([jdk], classpathComplete: true)
        let after = await index.sourcesVersion
        XCTAssertGreaterThan(after, before)
    }

    // MARK: - JDK switching and reopening

    /// Switching to a JDK that lacks a class makes it missing; switching back resolves it again.
    /// Nothing from the other JDK survives either way.
    func testSwitchingJDKsRejudgesTheSameText() async throws {
        let index = JavaIndex()
        let modern = try jdk()
        let old = JavaIndex.Source(precedence: 3, reader: try shard(Self.platform.filter { !$0.contains("LocalDate") }))
        await index.setSources([modern])
        let service = service(index)
        let doc = document("class T { java.time.LocalDate d; LocalDate e; }", url: scratch.appendingPathComponent("T.java"))
        await service.analyzeNow(doc)
        var found = await service.diagnostics(for: doc)
        XCTAssertEqual(codes(found), [])

        await index.setSources([old])
        await service.analyzeNow(doc)
        found = await service.diagnostics(for: doc)
        XCTAssertEqual(found.map(\.message), ["Cannot resolve type 'LocalDate'"])

        await index.setSources([modern])
        await service.analyzeNow(doc)
        found = await service.diagnostics(for: doc)
        XCTAssertEqual(codes(found), [])
    }

    /// Reopening a project is a new index state: an empty index again (pending), then the sources.
    func testReopenGoesThroughPendingAgain() async throws {
        let index = JavaIndex()
        let jdk = try jdk()
        await index.setSources([jdk])
        let service = service(index)
        let doc = document("class T { String s; Missing m; }", url: scratch.appendingPathComponent("T.java"))
        await service.analyzeNow(doc)
        var found = await service.diagnostics(for: doc)
        XCTAssertEqual(found.map(\.message), ["Cannot resolve type 'Missing'"])

        await index.setSources([], classpathComplete: false)   // folder closed and reopened
        await service.analyzeNow(doc)
        found = await service.diagnostics(for: doc)
        XCTAssertEqual(codes(found), [])

        await index.setSources([jdk])
        await service.analyzeNow(doc)
        found = await service.diagnostics(for: doc)
        XCTAssertEqual(found.map(\.message), ["Cannot resolve type 'Missing'"])
    }

    // MARK: - Ordering

    /// A pass that started before the JDK landed finishes after it. Its result is labelled with
    /// the sources it started against, so it is stale on arrival and the next request re-runs it;
    /// and a pass that already ran against the JDK is never overwritten by it.
    func testAPassOvertakenByNewSourcesIsNeverCurrent() async throws {
        let index = JavaIndex()
        let service = service(index)
        let doc = document("class T { String s; }", url: scratch.appendingPathComponent("T.java"))
        let gate = Gate()
        JavaInspectionService.analysisStartHook = { await gate.waitIfFirst() }
        defer { JavaInspectionService.analysisStartHook = nil }

        let slow = Task { await service.analyzeNow(doc, force: true) }   // labelled sourcesVersion 0
        await gate.waitUntilHeld()
        await index.setSources([try jdk()])                              // version 1 lands mid-pass
        await service.analyzeNow(doc)                                    // runs against version 1
        await gate.release()
        await slow.value

        let fresh = await service.isFresh(doc)
        XCTAssertTrue(fresh, "the newer pass's result stands")
        let found = await service.diagnostics(for: doc)
        XCTAssertEqual(codes(found), [])
    }

    // MARK: - Pending bookkeeping

    /// Regression: `analyzeNow` cancelled a queued pass but left it registered. The cancelled task
    /// could not release itself, so `settle()` awaited the finished task in a loop forever, which
    /// hung the whole suite whenever the churn test below re-queued a straddled pass.
    func testAnalyzeNowOverAQueuedPassLeavesNothingRegistered() async throws {
        let index = JavaIndex()
        await index.setSources([try jdk()])
        let service = JavaInspectionService(
            index: index, enabledRules: [.unresolvedType, .unresolvedImport], idleDelay: .seconds(60)
        )
        let doc = document(Self.resolutionTest, url: scratch.appendingPathComponent("ResolutionTest.java"))
        _ = await service.diagnostics(for: doc)   // queues a pass behind the 60 s idle delay
        let queued = await service.pendingPassCount
        XCTAssertEqual(queued, 1)
        await service.analyzeNow(doc, force: true)
        let left = await service.pendingPassCount
        XCTAssertEqual(left, 0, "the cancelled pass is still registered")
        // With a leaked entry the old `settle()` never returns and cannot be cancelled: stop here.
        guard left == 0 else { return }

        let settled = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await service.settle(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(settled, "settle() did not return")
        let fresh = await service.isFresh(doc)
        XCTAssertTrue(fresh)
    }

    // MARK: - Stress

    /// Resolve the sample over and over while the index is replaced underneath: empty, project
    /// only, incomplete, complete. Every published result must be empty (no state can make the
    /// sample's JDK types missing), and the last one, against the final sources, is current.
    func testRepeatedResolutionWhileSourcesChurn() async throws {
        let index = JavaIndex()
        let service = service(index)
        let box = Recorder()
        await service.setResultHandler { _, diagnostics in box.append(diagnostics) }
        let doc = document(Self.resolutionTest, url: scratch.appendingPathComponent("ResolutionTest.java"))
        let jdk = try jdk()
        let project = JavaIndex.Source(precedence: 1, reader: try shard(["package app; public class Helper { }"]))
        let states: [([JavaIndex.Source], Bool)] = [([], true), ([project], true), ([jdk], false), ([jdk, project], true)]

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for round in 0..<40 {
                    let (sources, complete) = states[round % states.count]
                    await index.setSources(sources, classpathComplete: complete)
                }
                await index.setSources([jdk, project])
            }
            group.addTask {
                for _ in 0..<80 { await service.analyzeNow(doc) }
            }
        }
        await service.analyzeNow(doc)
        await service.settle()   // a pass the churn straddled is queued again, not run inline
        let fresh = await service.isFresh(doc)
        XCTAssertTrue(fresh)
        XCTAssertFalse(box.all.isEmpty)
        let straddled = await service.straddledPasses
        print("CHURN straddled_passes=\(straddled) published=\(box.all.count)")
        XCTAssertTrue(box.all.allSatisfy(\.isEmpty), "a JDK type was reported missing: \(box.all.first { !$0.isEmpty } ?? [])")
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[Diagnostic]] = []
    func append(_ diagnostics: [Diagnostic]) { lock.lock(); stored.append(diagnostics); lock.unlock() }
    var all: [[Diagnostic]] { lock.lock(); defer { lock.unlock() }; return stored }
}
