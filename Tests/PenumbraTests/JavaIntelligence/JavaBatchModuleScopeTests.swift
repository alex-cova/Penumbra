import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// Inspect Code resolves every file against its own module, exactly as the live service does:
/// the same visible shards, the same required shards, the same module visibility.
final class JavaBatchModuleScopeTests: XCTestCase {
    private var scratch: URL!
    private var paths: JavaIndexPaths!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-batch-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        paths = JavaIndexPaths(root: scratch.appendingPathComponent("index-cache", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

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

    struct Fixture {
        let index: JavaIndex
        let model: JavaGradleProjectModel
        let files: [URL: String]
    }

    /// `:app` sees `good.jar` (indexed) and `broken.jar` (failed: no shard). `:core` sees neither,
    /// and `:lib` sees `good.jar` only.
    private func fixture() async throws -> Fixture {
        let good = scratch.appendingPathComponent("good.jar")
        let broken = scratch.appendingPathComponent("broken.jar")
        var dirs: [String: URL] = [:]
        for module in ["app", "core", "lib"] {
            let dir = scratch.appendingPathComponent("\(module)/src/main/java", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dirs[module] = dir
        }
        let model = JavaGradleProjectModel(
            formatVersion: 4, gradleVersion: "9.0",
            subprojects: [
                .init(path: ":app", directory: scratch.appendingPathComponent("app"),
                      sourceSets: [.init(name: "main", sourceDirs: [dirs["app"]!], compileClasspathJars: [good, broken])]),
                .init(path: ":core", directory: scratch.appendingPathComponent("core"),
                      sourceSets: [.init(name: "main", sourceDirs: [dirs["core"]!])]),
                .init(path: ":lib", directory: scratch.appendingPathComponent("lib"),
                      sourceSets: [.init(name: "main", sourceDirs: [dirs["lib"]!], compileClasspathJars: [good])]),
            ]
        )
        let index = JavaIndex()
        var sources: [JavaIndex.Source] = [
            .init(precedence: 3, reader: try reader(["package java.lang; public class Object { }", "package java.lang; public final class String { }"])),
            .init(precedence: 2, reader: try reader(["package org.good; public class Good { }"]), shardPath: paths.jarShard(good).path),
        ]
        for dir in dirs.values {
            sources.append(.init(precedence: 1, reader: try reader([]), shardPath: paths.projectSourcesShard(for: dir.standardizedFileURL).path))
        }
        await index.setSources(sources)
        let files: [URL: String] = [
            dirs["app"]!.appendingPathComponent("A.java"): "import org.good.Good;\nclass A { Good g; FromBroken b; }",
            dirs["core"]!.appendingPathComponent("C.java"): "import org.good.Good;\nclass C { Missing m; String s; }",
            dirs["lib"]!.appendingPathComponent("L.java"): "import org.good.Good;\nclass L { Good g; Missing m; }",
        ]
        return Fixture(index: index, model: model, files: files)
    }

    private func batchFindings(_ inspector: JavaBatchInspector, _ fixture: Fixture) async -> [String: [String]] {
        var options = JavaBatchInspector.Options(profile: .standard())
        options.onlyRules = [.unresolvedType, .unresolvedImport]
        var result: [String: [String]] = [:]
        for (url, text) in fixture.files {
            let found = await inspector.inspect(url: url, options: options) { _ in text }
            result[url.lastPathComponent] = found.map(\.message).sorted()
        }
        return result
    }

    private static let expected: [String: [String]] = [
        "A.java": [],                                                                 // broken.jar unknown: pending
        "C.java": ["Cannot resolve import 'org.good.Good'", "Cannot resolve type 'Missing'"],  // not on :core's classpath
        "L.java": ["Cannot resolve type 'Missing'"],                                  // unrelated to broken.jar
    ]

    /// Inspect Code with the per-file module context: `:app`'s failed jar keeps only `:app`
    /// pending; `:core` and `:lib` report their genuine misses.
    func testBatchJudgesEachFileAgainstItsOwnModule() async throws {
        let fixture = try await fixture()
        let inspector = JavaBatchInspector(index: fixture.index, resolutionScopes: JavaFileResolutionScopes(model: fixture.model, paths: paths))
        let found = await batchFindings(inspector, fixture)
        XCTAssertEqual(found, Self.expected)
    }

    /// The live service and Inspect Code over the same snapshot give the same findings, file by
    /// file, when the batch takes the service's scopes.
    func testLiveAndBatchAgree() async throws {
        let fixture = try await fixture()
        let service = JavaInspectionService(index: fixture.index, enabledRules: [.unresolvedType, .unresolvedImport], idleDelay: .zero)
        await service.setSourceSetClasspath(fixture.model, indexPaths: paths)
        var live: [String: [String]] = [:]
        for (url, text) in fixture.files {
            let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
            let doc = Document(
                url: url, displayName: url.lastPathComponent, contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
                viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
            )
            await service.analyzeNow(doc)
            live[url.lastPathComponent] = await service.diagnostics(for: doc).map(\.message).sorted()
        }
        let inspector = JavaBatchInspector(index: fixture.index, resolutionScopes: await service.resolutionScopes)
        let batch = await batchFindings(inspector, fixture)
        XCTAssertEqual(live, batch)
        XCTAssertEqual(live, Self.expected)
    }

    /// The old scope-only construction still runs (other callers), but cannot see a failed jar:
    /// pinned so the difference stays deliberate.
    func testScopeOnlyBatchCannotSeeAFailedJar() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        let paths = paths!
        let inspector = JavaBatchInspector(index: fixture.index, queryScope: { model.visibleShardPaths(forFile: $0, paths: paths) })
        let found = await batchFindings(inspector, fixture)
        XCTAssertEqual(found["A.java"], ["Cannot resolve type 'FromBroken'"])
    }
}

/// JPMS: an import from a package the required module does not export is reported (javac:
/// `package … is not visible`); one from an exported package resolves. Live inspection now
/// installs the file's module visibility as completion does.
final class JavaImportModuleVisibilityTests: XCTestCase {
    func testImportOfAnUnexportedPackageIsReported() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-jpms-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let paths = JavaIndexPaths(root: scratch.appendingPathComponent("index-cache", isDirectory: true))
        let libDir = scratch.appendingPathComponent("lib/src/main/java", isDirectory: true)
        let appDir = scratch.appendingPathComponent("app/src/main/java", isDirectory: true)
        let libSources = [
            "a/api/Api.java": "package a.api; public class Api { }",
            "a/internal/Impl.java": "package a.internal; public class Impl { }",
        ]
        for (path, text) in libSources {
            let url = libDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: appDir.appendingPathComponent("app"), withIntermediateDirectories: true)
        try "module a { exports a.api; }".write(to: libDir.appendingPathComponent("module-info.java"), atomically: true, encoding: .utf8)
        try "module app { requires a; }".write(to: appDir.appendingPathComponent("module-info.java"), atomically: true, encoding: .utf8)

        let model = JavaGradleProjectModel(
            formatVersion: 4, gradleVersion: "9.0",
            subprojects: [
                .init(path: ":lib", directory: scratch.appendingPathComponent("lib"), sourceSets: [.init(name: "main", sourceDirs: [libDir])]),
                .init(path: ":app", directory: scratch.appendingPathComponent("app"),
                      sourceSets: [.init(name: "main", sourceDirs: [appDir], projectDependencies: [.init(projectPath: ":lib", sourceSetName: "main")])]),
            ]
        )
        var libStubs: [JavaClassStub] = []
        for (path, text) in libSources {
            libStubs.append(contentsOf: JavaSourceStubBuilder.build(source: text, url: libDir.appendingPathComponent(path)).classes)
        }
        func shard(_ stubs: [JavaClassStub]) throws -> JavaIndexShardReader {
            let url = scratch.appendingPathComponent("\(UUID().uuidString).idx")
            try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
            return try JavaIndexShardReader(url: url)
        }
        let object = JavaSourceStubBuilder.build(source: "package java.lang; public class Object { }", url: scratch.appendingPathComponent("Object.java")).classes
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 3, reader: try shard(object)),
            .init(precedence: 1, reader: try shard(libStubs), shardPath: paths.projectSourcesShard(for: libDir.standardizedFileURL).path),
            .init(precedence: 1, reader: try shard([]), shardPath: paths.projectSourcesShard(for: appDir.standardizedFileURL).path),
        ])
        let service = JavaInspectionService(index: index, enabledRules: [.unresolvedImport], idleDelay: .zero)
        await service.setSourceSetClasspath(model, indexPaths: paths)
        let url = appDir.appendingPathComponent("app/Main.java")
        let text = "package app;\nimport a.api.Api;\nimport a.internal.Impl;\nclass Main { }\n"
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let doc = Document(
            url: url, displayName: "Main.java", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        await service.analyzeNow(doc)
        let found = await service.diagnostics(for: doc).map(\.message)
        XCTAssertEqual(found, ["Package 'a.internal' is not exported to this module"])
    }
}
