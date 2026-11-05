import XCTest
@testable import JavaIntelligence

final class JavaUsageSearchTests: XCTestCase {
    func testSearchFindsUsagesAcrossFiles() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("p/Foo.java", "package p; public class €Foo { public void run() {} }")
        try fixture.add("p/A.java", "package p; class A { Foo f; void go() { f.run(); } }")
        try fixture.add("p/B.java", "package p; class B { Foo f = new Foo(); }")
        try fixture.add("p/C.java", "package p; class C { int unrelated; }")
        let id = try await fixture.requireID()
        let usages = try await fixture.search(id)
        XCTAssertEqual(usages.map { $0.url.lastPathComponent }, ["A.java", "B.java", "B.java", "Foo.java"])
        XCTAssertEqual(usages.filter { $0.kind == .declaration }.count, 1)
        let withoutDeclarations = try await fixture.search(id, includeDeclarations: false)
        XCTAssertEqual(withoutDeclarations.count, 3)
    }

    func testMethodSearchHonoursOverloads() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { void €put(Foo f) {} void put(Bar b) {} }\nclass Foo {}\nclass Bar {}")
        try fixture.add("U.java", "class U { void go(A a, Foo f, Bar b) { a.put(f); a.put(b); a.put(f); } }")
        let id = try await fixture.requireID()
        let usages = try await fixture.search(id)
        XCTAssertEqual(usages.filter { $0.url.lastPathComponent == "U.java" }.count, 2)
    }

    func testLocalSearchNeedsNoCandidates() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { void go() { int €n = 1; n++; } }")
        try fixture.add("B.java", "class B { void go() { int n = 1; n++; } }")
        let id = try await fixture.requireID()
        let usages = try await fixture.search(id)
        XCTAssertEqual(usages.count, 2)
        XCTAssertTrue(usages.allSatisfy { $0.url.lastPathComponent == "A.java" })
    }

    func testOpenBufferTextWinsOverDisk() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class €A {}")
        try fixture.add("U.java", "class U { int x; }")
        let id = try await fixture.requireID()
        let base = try await fixture.build()
        let unsaved = fixture.url("U.java")
        var environment = base
        environment.openBuffer = { url in
            url.standardizedFileURL.path == unsaved.standardizedFileURL.path ? "class U { A a; }" : nil
        }
        let usages = await JavaUsageSearch.collect(
            id, candidates: JavaTextScanCandidateSource(textProvider: environment.openBuffer),
            roots: [fixture.root], environment: environment
        )
        XCTAssertEqual(usages.filter { $0.url.lastPathComponent == "U.java" }.count, 1)
    }

    func testCancellingTheConsumerStopsTheStream() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "class €Foo {}")
        for number in 0..<30 {
            try fixture.add("U\(number).java", "class U\(number) { Foo f; }")
        }
        let id = try await fixture.requireID()
        let environment = try await fixture.build()
        var received = 0
        for await _ in JavaUsageSearch.search(
            id, candidates: JavaTextScanCandidateSource(), roots: [fixture.root], environment: environment, maxConcurrentFiles: 1
        ) {
            received += 1
            if received == 3 { break }
        }
        XCTAssertEqual(received, 3)
    }

    func testTextScanCandidateSourceFiltersBySubstring() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { Widget w; }")
        try fixture.add("B.java", "class B {}")
        try fixture.add("notes.txt", "Widget")
        let files = await JavaTextScanCandidateSource().candidateFiles(containing: "Widget", in: [fixture.root])
        XCTAssertEqual(files.map(\.lastPathComponent), ["A.java"])
    }

    // MARK: - Gradle scope

    func testSourceSetsSeeingAShardAndScopedRoots() async throws {
        let fixture = try JavaReferenceFixture()
        let lib = fixture.root.appendingPathComponent("lib/src/main/java", isDirectory: true)
        let app = fixture.root.appendingPathComponent("app/src/main/java", isDirectory: true)
        let other = fixture.root.appendingPathComponent("other/src/main/java", isDirectory: true)
        try fixture.add("lib/src/main/java/Widget.java", "public class €Widget {}")
        try fixture.add("app/src/main/java/App.java", "class App { Widget w; }")
        try fixture.add("other/src/main/java/Other.java", "class Other { Widget w; }")
        let model = JavaGradleProjectModel(
            formatVersion: 4, gradleVersion: "9.0",
            subprojects: [
                .init(path: ":lib", directory: fixture.root, sourceSets: [.init(name: "main", sourceDirs: [lib])]),
                .init(
                    path: ":app", directory: fixture.root,
                    sourceSets: [.init(name: "main", sourceDirs: [app], projectDependencies: [.init(projectPath: ":lib", sourceSetName: "main")])]
                ),
                .init(path: ":other", directory: fixture.root, sourceSets: [.init(name: "main", sourceDirs: [other])])
            ]
        )
        let paths = JavaIndexPaths(root: fixture.root.appendingPathComponent("index-cache"))
        let libShard = paths.projectSourcesShard(for: lib.standardizedFileURL).path
        let seeing = model.sourceSets(seeing: libShard, paths: paths).map(\.subproject.path).sorted()
        XCTAssertEqual(seeing, [":app", ":lib"])

        let environment = try await fixture.build(gradleModel: model, indexPaths: paths)
        let id = try await fixture.requireID()
        let roots = await JavaUsageSearch.scopedRoots(for: id, roots: [lib, app, other], environment: environment)
        XCTAssertEqual(Set(roots.map(\.path)), [lib.path, app.path])

        let usages = await JavaUsageSearch.collect(
            id, candidates: JavaTextScanCandidateSource(), roots: [lib, app, other], environment: environment
        )
        XCTAssertEqual(usages.map { $0.url.lastPathComponent }, ["App.java", "Widget.java"])
    }

    // MARK: - F-08 work budget

    /// F-08: the files a search resolves are the benchmark. A module that cannot see the
    /// target is scoped out before any read: its files are never parsed, so decoy spellings
    /// there can neither slow the search nor leak in as false positives.
    func testOutOfScopeModuleIsNeverReadForTypeTarget() async throws {
        let fixture = try JavaReferenceFixture()
        let lib = fixture.root.appendingPathComponent("lib/src/main/java", isDirectory: true)
        let app = fixture.root.appendingPathComponent("app/src/main/java", isDirectory: true)
        let other = fixture.root.appendingPathComponent("other/src/main/java", isDirectory: true)
        try fixture.add("lib/src/main/java/Widget.java", "public class €Widget {}")
        try fixture.add("app/src/main/java/App.java", "class App { Widget w; }")
        try fixture.add("other/src/main/java/Other.java", "class Other { Widget w; }")
        var environment = try await fixture.build(
            gradleModel: Self.threeModuleModel(root: fixture.root, lib: lib, app: app, other: other),
            indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("index-cache"))
        )
        let readFiles = LockedSet<String>()
        environment.openBuffer = fixture.countingReader(into: readFiles)
        let id = try await fixture.requireID()
        let usages = await JavaUsageSearch.collect(
            id, candidates: JavaTextScanCandidateSource(), roots: [lib, app, other], environment: environment
        )
        XCTAssertEqual(usages.map { $0.url.lastPathComponent }.sorted(), ["App.java", "Widget.java"])
        XCTAssertEqual(readFiles.sorted(), [fixture.url("app/src/main/java/App.java").standardizedFileURL.path, fixture.url("lib/src/main/java/Widget.java").standardizedFileURL.path])
        XCTAssertFalse(readFiles.contains(where: { $0.hasPrefix(other.standardizedFileURL.path) }))
    }

    /// F-08: same work budget for a method target with an overload-shaped decoy: `Other.run`
    /// is its own method, and `Other` cannot see `Widget`, so only `App`'s call resolves.
    func testOutOfScopeModuleIsNeverReadForMethodTarget() async throws {
        let fixture = try JavaReferenceFixture()
        let lib = fixture.root.appendingPathComponent("lib/src/main/java", isDirectory: true)
        let app = fixture.root.appendingPathComponent("app/src/main/java", isDirectory: true)
        let other = fixture.root.appendingPathComponent("other/src/main/java", isDirectory: true)
        try fixture.add("lib/src/main/java/Widget.java", "public class Widget { public void €run() {} }")
        try fixture.add("app/src/main/java/App.java", "class App { Widget w; void go() { w.run(); } }")
        try fixture.add("other/src/main/java/Other.java", "class Other { void run() {} void go() { run(); } }")
        var environment = try await fixture.build(
            gradleModel: Self.threeModuleModel(root: fixture.root, lib: lib, app: app, other: other),
            indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("index-cache"))
        )
        let readFiles = LockedSet<String>()
        environment.openBuffer = fixture.countingReader(into: readFiles)
        let id = try await fixture.requireID()
        let usages = await JavaUsageSearch.collect(
            id, candidates: JavaTextScanCandidateSource(), roots: [lib, app, other], environment: environment
        )
        XCTAssertEqual(usages.map { $0.url.lastPathComponent }.sorted(), ["App.java", "Widget.java"])
        XCTAssertEqual(readFiles.sorted(), [fixture.url("app/src/main/java/App.java").standardizedFileURL.path, fixture.url("lib/src/main/java/Widget.java").standardizedFileURL.path])
        XCTAssertFalse(readFiles.contains(where: { $0.hasPrefix(other.standardizedFileURL.path) }))
    }

    private static func threeModuleModel(root: URL, lib: URL, app: URL, other: URL) -> JavaGradleProjectModel {
        JavaGradleProjectModel(
            formatVersion: 4, gradleVersion: "9.0",
            subprojects: [
                .init(path: ":lib", directory: root, sourceSets: [.init(name: "main", sourceDirs: [lib])]),
                .init(
                    path: ":app", directory: root,
                    sourceSets: [.init(name: "main", sourceDirs: [app], projectDependencies: [.init(projectPath: ":lib", sourceSetName: "main")])]
                ),
                .init(path: ":other", directory: root, sourceSets: [.init(name: "main", sourceDirs: [other])])
            ]
        )
    }
}

/// F-08: records every file a search reads through the open-buffer hook. `JavaUsageSearch`
/// reads resolve-candidates through `openBuffer` when set, so the recorded set is exactly the
/// files the search parsed and resolved — the work a persistent reference index would remove.
private final class LockedSet<Element: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<Element>()

    func insert(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }
        values.insert(element)
    }

    func contains(where predicate: (Element) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.contains(where: predicate)
    }

    func sorted() -> [Element] where Element: Comparable {
        lock.lock()
        defer { lock.unlock() }
        return values.sorted()
    }
}

private extension JavaReferenceFixture {
    /// Serves every fixture file through the counting hook, keyed by standardized path.
    func countingReader(into readFiles: LockedSet<String>) -> (@Sendable (URL) async -> String?) {
        let rootPath = root.standardizedFileURL.path
        let sources = sources
        return { url in
            let path = url.standardizedFileURL.path
            readFiles.insert(path)
            guard path.hasPrefix(rootPath + "/") else { return nil }
            return sources[String(path.dropFirst(rootPath.count + 1))]
        }
    }
}
