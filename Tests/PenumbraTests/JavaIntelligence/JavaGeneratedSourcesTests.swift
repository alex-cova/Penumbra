import XCTest
@testable import JavaIntelligence

/// F23: annotation-processor output is rewritten in place, below a directory whose own mtime does
/// not move, and is not watched like a source root. Its stamp has to say what is in it, and the
/// host has to know which watcher paths concern it.
final class JavaGeneratedSourcesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("java-generated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ path: String, _ text: String, modified: TimeInterval? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - The stamp

    /// What the old stamp could not see: a nested file rewritten in place.
    func testGeneratedRootStampSeesANestedRewriteThatTheDirectoryStampMisses() throws {
        try write("gen/p/Foo_Impl.java", "package p; class Foo_Impl {}", modified: 1_700_000_000)
        let regular = SourceRoot(directory: root.appendingPathComponent("gen"))
        let generated = SourceRoot(directory: root.appendingPathComponent("gen"), isGenerated: true)
        let before = (regular.stamp, generated.stamp)
        try write("gen/p/Foo_Impl.java", "package p; class Foo_Impl { void added() {} }", modified: 1_700_000_100)
        XCTAssertEqual(regular.stamp, before.0, "a regular root's stamp is the directory's own mtime")
        XCTAssertNotEqual(generated.stamp, before.1)
    }

    func testGeneratedRootStampMovesForEveryKindOfChange() throws {
        try write("gen/p/A.java", "package p; class A {}", modified: 1_700_000_000)
        let generated = SourceRoot(directory: root.appendingPathComponent("gen"), isGenerated: true)
        var seen = [generated.stamp]
        func changed(_ what: String) {
            let stamp = generated.stamp
            XCTAssertFalse(seen.contains(stamp), "\(what) did not change the stamp")
            seen.append(stamp)
        }
        try write("gen/p/B.java", "package p; class B {}", modified: 1_700_000_001)
        changed("adding a file")
        try write("gen/q/deep/C.java", "package q.deep; class C {}", modified: 1_700_000_002)
        changed("adding a file in a new nested package")
        // Same length: only the newest modification time can tell this rewrite apart.
        try write("gen/p/A.java", "package p; class X {}", modified: 1_700_000_050)
        changed("rewriting a file with the same length")
        try FileManager.default.removeItem(at: root.appendingPathComponent("gen/q/deep/C.java"))
        changed("removing a file")
    }

    func testGeneratedRootStampIsStableWhenNothingChanged() throws {
        try write("gen/p/A.java", "package p; class A {}")
        try write("gen/p/notes.txt", "not java")
        let generated = SourceRoot(directory: root.appendingPathComponent("gen"), isGenerated: true)
        let first = generated.stamp
        XCTAssertEqual(generated.stamp, first)
        XCTAssertEqual(generated.stamp, first)
    }

    func testFilesThatAreNotJavaDoNotMoveTheStamp() throws {
        try write("gen/p/A.java", "package p; class A {}", modified: 1_700_000_000)
        let generated = SourceRoot(directory: root.appendingPathComponent("gen"), isGenerated: true)
        let before = generated.stamp
        try write("gen/p/A.class", "bytes", modified: 1_800_000_000)
        try write("gen/p/.DS_Store", "x", modified: 1_800_000_000)
        // The directory now has a newer mtime than the java file, so the date moves; what must not
        // move is the count and size half.
        XCTAssertEqual(generated.stamp.size, before.size)
    }

    // MARK: - Through the scheduler

    /// The real path: index a generated root, let a processor rewrite a nested file, index again
    /// without `force`. The stale shard has to be replaced, and an untouched root has to be skipped.
    func testSchedulerReindexesARewrittenGeneratedFileAndSkipsAnUntouchedRoot() async throws {
        try write("gen/p/Foo_Impl.java", "package p; class Foo_Impl {}", modified: 1_700_000_000)
        let generated = SourceRoot(directory: root.appendingPathComponent("gen"), isGenerated: true)
        let shard = root.appendingPathComponent("gen.idx")
        let scheduler = JavaIndexScheduler(paths: JavaIndexPaths(root: root.appendingPathComponent("cache")))

        func run() async -> [JavaIndexScheduler.Progress] {
            var events: [JavaIndexScheduler.Progress] = []
            for await event in await scheduler.index([(root: generated, shardURL: shard)]) { events.append(event) }
            return events
        }

        var events = await run()
        XCTAssertTrue(events.contains(.rootFinished(id: generated.id, classCount: 1)), "\(events)")
        XCTAssertEqual(try JavaIndexShardReader(url: shard).allQualifiedNames, ["p.Foo_Impl"])

        events = await run()
        XCTAssertTrue(events.contains { if case .rootSkipped = $0 { return true } else { return false } }, "an untouched root is skipped: \(events)")

        try write("gen/p/Foo_Impl.java", "package p; class Foo_Impl {} class Extra {}", modified: 1_700_000_200)
        events = await run()
        XCTAssertTrue(events.contains(.rootFinished(id: generated.id, classCount: 2)), "the rewrite is picked up: \(events)")
        XCTAssertEqual(Set(try JavaIndexShardReader(url: shard).allQualifiedNames), ["p.Foo_Impl", "p.Extra"])
    }

    // MARK: - Which watcher paths concern generated sources

    private func model(generated: [String]) -> JavaGradleProjectModel {
        let set = JavaGradleProjectModel.SourceSet(
            name: "main",
            sourceDirs: [root.appendingPathComponent("src/main/java")],
            generatedSourceDirs: generated.map { root.appendingPathComponent($0) }
        )
        return JavaGradleProjectModel(
            formatVersion: 5, gradleVersion: "8.5",
            subprojects: [.init(path: ":", directory: root, sourceSets: [set])]
        )
    }

    func testWatcherPathsInsideAGeneratedDirectoryConcernIt() {
        let model = model(generated: ["build/generated/sources/annotationProcessor/java/main"])
        let gen = root.appendingPathComponent("build/generated/sources/annotationProcessor/java/main")
        XCTAssertTrue(model.affectsGeneratedSources([gen.appendingPathComponent("p/Foo_Impl.java")]))
        XCTAssertTrue(model.affectsGeneratedSources([gen.appendingPathComponent("p")]), "a package directory")
        XCTAssertTrue(model.affectsGeneratedSources([gen]), "the root itself")
    }

    /// A first build creates `build/`, a clean removes it: both are events on a parent.
    func testAParentOfAGeneratedDirectoryConcernsIt() {
        let model = model(generated: ["build/generated/sources/annotationProcessor/java/main"])
        XCTAssertTrue(model.affectsGeneratedSources([root.appendingPathComponent("build")]))
        XCTAssertTrue(model.affectsGeneratedSources([root.appendingPathComponent("build/generated")]))
    }

    func testOtherPathsDoNot() {
        let model = model(generated: ["build/generated/sources/annotationProcessor/java/main"])
        let gen = root.appendingPathComponent("build/generated/sources/annotationProcessor/java/main")
        XCTAssertFalse(model.affectsGeneratedSources([root.appendingPathComponent("src/main/java/p/Foo.java")]))
        XCTAssertFalse(model.affectsGeneratedSources([root.appendingPathComponent("build/classes/java/main/p/Foo.class")]))
        XCTAssertFalse(model.affectsGeneratedSources([gen.appendingPathComponent("p/Foo_Impl.class")]), "only java files count inside")
        XCTAssertFalse(model.affectsGeneratedSources([root.appendingPathComponent("build.gradle")]))
        XCTAssertFalse(model.affectsGeneratedSources([root.appendingPathComponent("build-notes/readme.md")]), "a name that merely starts with `build`")
        XCTAssertFalse(self.model(generated: []).affectsGeneratedSources([gen.appendingPathComponent("p/Foo_Impl.java")]))
    }

    /// Normal paths skip standardizing (it costs milliseconds per 10k-path batch on the main
    /// actor); a path with dot segments must still be judged by where it really points.
    func testPathsWithDotSegmentsAreStillStandardized() {
        let model = model(generated: ["build/generated/sources/annotationProcessor/java/main"])
        let gen = root.appendingPathComponent("build/generated/sources/annotationProcessor/java/main")
        let viaParent = URL(fileURLWithPath: gen.path + "/p/../p/Foo_Impl.java")
        XCTAssertTrue(model.affectsGeneratedSources([viaParent]))
        let escaping = URL(fileURLWithPath: gen.path + "/../../../../../../src/main/java/p/Foo.java")
        XCTAssertFalse(model.affectsGeneratedSources([escaping]))
    }

    func testADeclaredDirectoryThatDoesNotExistYetStillCounts() throws {
        let model = model(generated: ["build/generated/sources/annotationProcessor/java/main"])
        XCTAssertEqual(model.existingGeneratedSourceDirectories, [], "nothing built yet")
        XCTAssertEqual(model.declaredGeneratedSourceDirectories.count, 1)
        XCTAssertTrue(model.affectsGeneratedSources([root.appendingPathComponent("build/generated")]))
    }
}
