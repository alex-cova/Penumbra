import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// Second-pass audit of the readiness fix: module scopes, failed shards, out-of-order passes,
/// publication bursts. Every ordering is forced with `JavaInspectionService.analysisStartHook`
/// or `JavaIndex.sourcesBuildHook`; nothing sleeps.
final class JavaResolutionAuditTests: XCTestCase {
    private var scratch: URL!
    private var paths: JavaIndexPaths!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        paths = JavaIndexPaths(root: scratch.appendingPathComponent("index-cache", isDirectory: true))
    }

    override func tearDownWithError() throws {
        JavaInspectionService.analysisStartHook = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Fixtures

    private static let platform = [
        "package java.lang; public class Object { }",
        "package java.lang; public final class String { }",
        "package java.util; public interface List<E> { }",
    ]

    private func reader(_ sources: [String]) throws -> JavaIndexShardReader {
        var stubs: [JavaClassStub] = []
        for source in sources {
            let file = scratch.appendingPathComponent("S\(UUID().uuidString).java")
            try source.write(to: file, atomically: true, encoding: .utf8)
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: file).classes)
        }
        let url = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        return try JavaIndexShardReader(url: url)
    }

    private func jdk() throws -> JavaIndex.Source { .init(precedence: 3, reader: try reader(Self.platform)) }

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

    private func service(_ index: JavaIndex) -> JavaInspectionService {
        JavaInspectionService(index: index, enabledRules: [.unresolvedType, .unresolvedImport], idleDelay: .zero)
    }

    private func messages(_ diagnostics: [Diagnostic]) -> [String] { diagnostics.map(\.message).sorted() }

    /// Two modules, `:app` (whose classpath is `appJars`) and `:core` (no jars), each with a source
    /// directory on disk. Returns the model and the file URL in each module.
    private struct Project {
        let model: JavaGradleProjectModel
        let appFile: URL
        let coreFile: URL
        let appShard: String
        let coreShard: String
    }

    private func project(appJars: [URL]) throws -> Project {
        let appDir = scratch.appendingPathComponent("app/src/main/java", isDirectory: true)
        let coreDir = scratch.appendingPathComponent("core/src/main/java", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: coreDir, withIntermediateDirectories: true)
        let model = JavaGradleProjectModel(
            formatVersion: 4, gradleVersion: "9.0",
            subprojects: [
                .init(path: ":app", directory: scratch.appendingPathComponent("app"),
                      sourceSets: [.init(name: "main", sourceDirs: [appDir], compileClasspathJars: appJars)]),
                .init(path: ":core", directory: scratch.appendingPathComponent("core"),
                      sourceSets: [.init(name: "main", sourceDirs: [coreDir])]),
            ]
        )
        return Project(
            model: model,
            appFile: appDir.appendingPathComponent("A.java"),
            coreFile: coreDir.appendingPathComponent("C.java"),
            appShard: paths.projectSourcesShard(for: appDir.standardizedFileURL).path,
            coreShard: paths.projectSourcesShard(for: coreDir.standardizedFileURL).path
        )
    }

    private func jarSource(_ jar: URL, _ classes: [String]) throws -> JavaIndex.Source {
        .init(precedence: 2, reader: try reader(classes), shardPath: paths.jarShard(jar).path)
    }

    private func projectSource(_ shardPath: String) throws -> JavaIndex.Source {
        .init(precedence: 1, reader: try reader([]), shardPath: shardPath)
    }

    // MARK: - False negatives (the audit's example)

    func testGenuineMissesReportAndStringResolves() async throws {
        let index = JavaIndex()
        await index.setSources([try jdk()])
        let service = service(index)
        let doc = document("""
        import java.util.DoesNotExist;

        public class Test {
            private MissingClass missing;
            private String valid;
        }
        """, url: scratch.appendingPathComponent("Test.java"))
        await service.analyzeNow(doc)
        let found = await service.diagnostics(for: doc)
        XCTAssertEqual(messages(found), [
            "Cannot resolve import 'java.util.DoesNotExist'",
            "Cannot resolve type 'MissingClass'",
        ])
    }

    // MARK: - D1: module scope is part of the resolution context

    /// A dependency is added to `:app` (the model changes, the index already held the jar from
    /// another module's earlier sync). The same text against the same sources must be re-judged
    /// against the new scope.
    func testModelChangeInvalidatesCachedResults() async throws {
        let jar = scratch.appendingPathComponent("inject.jar")
        let before = try project(appJars: [])
        let after = try project(appJars: [jar])
        let index = JavaIndex()
        await index.setSources([
            try jdk(), try projectSource(before.appShard), try projectSource(before.coreShard),
            try jarSource(jar, ["package jakarta.inject; public @interface Inject { }"]),
        ])
        let service = service(index)
        await service.setSourceSetClasspath(before.model, indexPaths: paths)
        let doc = document("import jakarta.inject.Inject;\nclass A { Inject marker; }", url: before.appFile)
        await service.analyzeNow(doc)
        let off = await service.diagnostics(for: doc)
        XCTAssertEqual(messages(off), [
            "Cannot resolve import 'jakarta.inject.Inject'",
            "Cannot resolve type 'Inject'",
        ], "not on :app's classpath: a genuine error")

        await service.setSourceSetClasspath(after.model, indexPaths: paths)
        let fresh = await service.isFresh(doc)
        XCTAssertFalse(fresh, "a result judged against another classpath is stale")
        await service.analyzeNow(doc)
        let on = await service.diagnostics(for: doc)
        XCTAssertEqual(messages(on), [])
    }

    // MARK: - D2: a classpath root that failed to index

    /// `:app`'s jar failed to index (corrupt, missing, cancelled): its shard is not among the
    /// sources. `:app` cannot prove a class missing; `:core`, which does not see that jar, still can.
    func testAFailedShardKeepsOnlyItsModulePending() async throws {
        let jar = scratch.appendingPathComponent("broken.jar")
        let project = try project(appJars: [jar])
        let index = JavaIndex()
        await index.setSources([try jdk(), try projectSource(project.appShard), try projectSource(project.coreShard)])
        let service = service(index)
        await service.setSourceSetClasspath(project.model, indexPaths: paths)

        let app = document("class A { FromBrokenJar x; }", url: project.appFile)
        await service.analyzeNow(app)
        let appFindings = await service.diagnostics(for: app)
        XCTAssertEqual(messages(appFindings), [], ":app's classpath is incomplete")

        let core = document("class C { Missing y; String s; }", url: project.coreFile)
        await service.analyzeNow(core)
        let coreFindings = await service.diagnostics(for: core)
        XCTAssertEqual(messages(coreFindings), ["Cannot resolve type 'Missing'"], "an unrelated module stays authoritative")
    }

    // MARK: - D3: an older text never overwrites a newer one

    /// Text A's pass is held; the user types (text B), B's pass lands; A's pass finishes last.
    /// The cache and the last published result must be B's.
    func testAnOlderTextFinishingLastDoesNotOverwrite() async throws {
        let index = JavaIndex()
        await index.setSources([try jdk()])
        let service = service(index)
        let published = Published()
        await service.setResultHandler { _, diagnostics in published.append(diagnostics) }
        let url = scratch.appendingPathComponent("T.java")
        let textA = document("class T { MissingA a; }", url: url)
        let textB = document("class T { String b; }", url: url)

        let gate = Gate()
        JavaInspectionService.analysisStartHook = { await gate.waitIfFirst() }
        let slow = Task { await service.analyzeNow(textA) }
        await gate.waitUntilHeld()
        await service.analyzeNow(textB)
        await gate.release()
        await slow.value

        let fresh = await service.isFresh(textB)
        XCTAssertTrue(fresh, "B's result is what the cache holds")
        XCTAssertEqual(published.all.last.map(messages), [], "the last published result is B's")
    }

    // MARK: - D5: republishing the same sources is not a change

    func testRepublishingIdenticalSourcesKeepsTheVersion() async throws {
        let index = JavaIndex()
        let sources = [try jdk()]
        await index.setSources(sources)
        let first = await index.sourcesVersion
        await index.setSources(sources)
        let second = await index.sourcesVersion
        XCTAssertEqual(first, second, "nothing a query can see changed")
        await index.setSources(sources, classpathComplete: false)
        let third = await index.sourcesVersion
        XCTAssertGreaterThan(third, second, "the completeness flag is part of what changed")
    }

    // MARK: - D4: publication bursts coalesce

    /// Five publishes land while the first re-check is held. Each publish asks for a re-check of
    /// the same open file; only the newest may run to publication, and older queued passes are
    /// cancelled. Measured as passes that ran to the end and results published.
    func testABurstOfPublishesCoalesces() async throws {
        let index = JavaIndex()
        let service = service(index)
        let published = Published()
        await service.setResultHandler { _, diagnostics in published.append(diagnostics) }
        let doc = document("class T { String s; Missing m; }", url: scratch.appendingPathComponent("T.java"))
        let jdk = try jdk()

        let gate = Gate()
        JavaInspectionService.analysisStartHook = { await gate.waitIfFirst() }
        await index.setSources([jdk], classpathComplete: false)
        await service.refreshAfterIndexChange([doc])        // pass 1, held at the gate
        await gate.waitUntilHeld()
        for round in 0..<5 {                                // five more publishes meanwhile
            await index.setSources([jdk], classpathComplete: round % 2 == 0)
            await service.refreshAfterIndexChange([doc])
        }
        await gate.release()
        await service.settle()

        let fresh = await service.isFresh(doc)
        XCTAssertTrue(fresh)
        let full = await service.completedPasses
        let cancelled = await service.cancelledPasses
        print("COALESCE publishes=6 full_passes=\(full) cancelled_passes=\(cancelled) published=\(published.all.count)")
        XCTAssertLessThanOrEqual(full, 2, "the newest pass, plus at most one that finished before the next publish")
        XCTAssertEqual(published.all.count, 1, "only the newest key publishes")
        XCTAssertEqual(published.all.last.map(messages), ["Cannot resolve type 'Missing'"])
    }

    /// A file whose result is already current is not re-run by a publish that did not move it.
    func testRefreshSkipsCurrentResults() async throws {
        let index = JavaIndex()
        let sources = [try jdk()]
        await index.setSources(sources)
        let service = service(index)
        let doc = document("class T { String s; }", url: scratch.appendingPathComponent("T.java"))
        await service.analyzeNow(doc)
        await index.setSources(sources)                     // identical: version unchanged
        await service.refreshAfterIndexChange([doc])
        let passes = await service.completedPasses
        XCTAssertEqual(passes, 1)
    }

    // MARK: - Pending is visible as pending

    func testPendingIsDistinguishableFromClean() async throws {
        let index = JavaIndex()
        let service = service(index)
        let url = scratch.appendingPathComponent("T.java")
        let doc = document("class T { String s; }", url: url)
        await service.analyzeNow(doc)
        var pending = await service.isResolutionPending(for: url)
        XCTAssertTrue(pending, "no JDK: the empty result is uncertainty")

        await index.setSources([try jdk()])
        await service.refreshAfterIndexChange([doc])
        await service.settle()
        pending = await service.isResolutionPending(for: url)
        XCTAssertFalse(pending, "authoritative: the empty result is a clean bill")
    }

    // MARK: - Configuration changes during a pass

    /// The profile turns `unresolved-type` off while a pass that still has it on is running. That
    /// pass must not be stored as the current result for the new profile.
    func testAProfileChangeDuringAPassIsNotOvertakenByIt() async throws {
        let index = JavaIndex()
        await index.setSources([try jdk()])
        let service = service(index)
        let doc = document("class T { Missing m; }", url: scratch.appendingPathComponent("T.java"))
        let gate = Gate()
        JavaInspectionService.analysisStartHook = { await gate.waitIfFirst() }
        let slow = Task { await service.analyzeNow(doc) }
        await gate.waitUntilHeld()
        await service.setEnabledRules([.unresolvedImport])
        await gate.release()
        await slow.value
        let fresh = await service.isFresh(doc)
        XCTAssertFalse(fresh, "judged under the old profile")
        await service.analyzeNow(doc)
        let found = await service.diagnostics(for: doc)
        XCTAssertEqual(messages(found), [])
    }

    // MARK: - Module re-sync

    /// `:app` gains a jar; the model is handed over before the jar is indexed. `:app` is pending
    /// until its shard is published, `:core` keeps reporting throughout, and once the jar lands
    /// `:app` resolves it and still reports a real miss.
    func testResyncKeepsUnchangedModulesAuthoritative() async throws {
        let jar = scratch.appendingPathComponent("new-dep.jar")
        let before = try project(appJars: [])
        let after = try project(appJars: [jar])
        let index = JavaIndex()
        let base = [try jdk(), try projectSource(before.appShard), try projectSource(before.coreShard)]
        await index.setSources(base)
        let service = service(index)
        await service.setSourceSetClasspath(after.model, indexPaths: paths)   // sync applied, jar not indexed

        let app = document("import org.dep.Thing;\nclass A { Thing t; Missing m; }", url: after.appFile)
        let core = document("class C { Missing m; }", url: after.coreFile)
        await service.analyzeNow(app)
        await service.analyzeNow(core)
        var appFound = await service.diagnostics(for: app)
        let coreFound = await service.diagnostics(for: core)
        XCTAssertEqual(messages(appFound), [])
        XCTAssertEqual(messages(coreFound), ["Cannot resolve type 'Missing'"])

        await index.setSources(base + [try jarSource(jar, ["package org.dep; public class Thing { }"])])
        await service.refreshAfterIndexChange([app, core])
        await service.settle()
        appFound = await service.diagnostics(for: app)
        XCTAssertEqual(messages(appFound), ["Cannot resolve type 'Missing'"])
    }

    // MARK: - Ordering of index publication

    /// The JDK lands first; the project's own shard is still indexing (the host says incomplete).
    /// A class from another project file is pending, then resolves once the shard is published.
    func testJDKBeforeProjectSources() async throws {
        let index = JavaIndex()
        let jdk = try jdk()
        await index.setSources([jdk], classpathComplete: false)
        let service = service(index)
        let doc = document("package app;\nclass T { Helper h; String s; }", url: scratch.appendingPathComponent("T.java"))
        await service.analyzeNow(doc)
        var found = await service.diagnostics(for: doc)
        XCTAssertEqual(messages(found), [])

        await index.setSources([jdk, .init(precedence: 1, reader: try reader(["package app; public class Helper { }"]))])
        await service.refreshAfterIndexChange([doc])
        await service.settle()
        found = await service.diagnostics(for: doc)
        XCTAssertEqual(messages(found), [])
        let pending = await service.isResolutionPending(for: doc.url!)
        XCTAssertFalse(pending)
    }

    /// A newer `setSources` overtakes an older one still building its tables: the older call's
    /// sources and completeness flag never apply.
    func testAnOvertakenPublishNeverApplies() async throws {
        let index = JavaIndex()
        let jdk = try jdk()
        let gate = Gate()
        JavaIndex.sourcesBuildHook = { await gate.waitIfFirst() }
        defer { JavaIndex.sourcesBuildHook = nil }
        let older = Task { await index.setSources([jdk], classpathComplete: true) }
        await gate.waitUntilHeld()
        await index.setSources([], classpathComplete: false)
        await gate.release()
        await older.value
        let canProve = await index.canProveAbsence
        let complete = await index.classpathComplete
        XCTAssertFalse(canProve)
        XCTAssertFalse(complete)
    }

    // MARK: - Workspaces

    /// Two windows share one JDK reader (the shared shard hub) but each has its own index and
    /// service. One being incomplete never silences the other, and their caches never mix.
    func testTwoWorkspacesStayIndependent() async throws {
        let shared = try jdk()
        let ready = JavaIndex()
        let loading = JavaIndex()
        await ready.setSources([shared])
        await loading.setSources([shared], classpathComplete: false)
        let readyService = service(ready)
        let loadingService = service(loading)
        let url = scratch.appendingPathComponent("T.java")
        let doc = document("class T { Missing m; }", url: url)
        await readyService.analyzeNow(doc)
        await loadingService.analyzeNow(doc)
        let readyFound = await readyService.diagnostics(for: doc)
        let loadingFound = await loadingService.diagnostics(for: doc)
        XCTAssertEqual(messages(readyFound), ["Cannot resolve type 'Missing'"])
        XCTAssertEqual(messages(loadingFound), [])
    }

    // MARK: - Rapid edits

    /// The user types while a pass runs and the index is replaced: ten texts, each requested, with
    /// a publish in the middle. The cache ends on the last text against the last sources, and no
    /// published result ever claims `String` is missing.
    func testRapidEditsWhileSourcesChange() async throws {
        let index = JavaIndex()
        let jdk = try jdk()
        let service = service(index)
        let published = Published()
        await service.setResultHandler { _, diagnostics in published.append(diagnostics) }
        let url = scratch.appendingPathComponent("T.java")
        let gate = Gate()
        JavaInspectionService.analysisStartHook = { await gate.waitIfFirst() }
        let opening = document("class T { String s0; }", url: url)
        let first = Task { await service.analyzeNow(opening) }
        await gate.waitUntilHeld()
        var last = document("", url: url)
        for edit in 1...10 {
            if edit == 5 { await index.setSources([jdk]) }
            last = document("class T { String s\(edit); }", url: url)
            _ = await service.diagnostics(for: last)
        }
        await gate.release()
        await first.value
        await service.analyzeNow(last)
        let fresh = await service.isFresh(last)
        XCTAssertTrue(fresh)
        XCTAssertTrue(published.all.allSatisfy { messages($0).isEmpty })
    }
}

actor Gate {
    private var held = false
    private var used = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    /// The first caller blocks until `release()`; later callers pass straight through.
    func waitIfFirst() async {
        guard !used else { return }
        used = true
        held = true
        heldWaiters.forEach { $0.resume() }
        heldWaiters = []
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}

final class Published: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[Diagnostic]] = []
    func append(_ diagnostics: [Diagnostic]) { lock.lock(); stored.append(diagnostics); lock.unlock() }
    var all: [[Diagnostic]] { lock.lock(); defer { lock.unlock() }; return stored }
}
