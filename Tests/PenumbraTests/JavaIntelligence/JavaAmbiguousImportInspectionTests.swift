import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// `JavaAmbiguousImportInspection`: a simple type name that two on-demand imports both provide
/// reports at its first type-position reference (the resolver leaves it `.unresolved` instead
/// of picking a match). A single provider, an unreferenced collision, and a name no import
/// provides all stay silent.
final class JavaAmbiguousImportInspectionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-ambiguous-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func findings(_ source: String, libraries: [String] = []) async throws -> [JavaInspection] {
        let index = try await makeIndex(libraries: libraries)
        let url = scratch.appendingPathComponent("T.java")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: index))
        // Through the typed runner, so registration and the runner path are covered too.
        let all = await JavaInspectionRunner.runTyped(context: context, enabled: [.ambiguousImport])
        return all.filter { $0.id == "ambiguous-import" }
    }

    private func makeIndex(libraries: [String] = []) async throws -> JavaIndex {
        var stubs: [JavaClassStub] = []
        for (number, library) in libraries.enumerated() {
            let file = scratch.appendingPathComponent("Lib\(number).java")
            try library.write(to: file, atomically: true, encoding: .utf8)
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: library, url: file).classes)
        }
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        return index
    }

    // MARK: - Reports

    func testTwoProvidersReport() async throws {
        let found = try await findings(
            "import java.util.*; import java.awt.*; class T { List items; }",
            libraries: [
                "package java.util; public class List { }",
                "package java.awt; public class List { }",
            ]
        )
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first?.message.contains("'java.util.List'") == true, "\(found)")
        XCTAssertTrue(found.first?.message.contains("'java.awt.List'") == true, "\(found)")
    }

    // MARK: - Silent

    func testSingleProviderIsSilent() async throws {
        let found = try await findings(
            "import java.io.*; import java.util.*; class T { List items; }",
            libraries: ["package java.util; public class List { }"]
        )
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testUnreferencedCollisionIsSilent() async throws {
        let found = try await findings(
            "import java.util.*; import java.awt.*; class T { int x; }",
            libraries: [
                "package java.util; public class List { }",
                "package java.awt; public class List { }",
            ]
        )
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testUnprovidedNameIsSilent() async throws {
        // No import provides the name: the unresolved-type rule owns that, not this one.
        let found = try await findings(
            "import java.util.*; import java.awt.*; class T { Ghost g; }",
            libraries: [
                "package java.util; public class List { }",
                "package java.awt; public class List { }",
            ]
        )
        XCTAssertTrue(found.isEmpty, "\(found)")
    }
}
