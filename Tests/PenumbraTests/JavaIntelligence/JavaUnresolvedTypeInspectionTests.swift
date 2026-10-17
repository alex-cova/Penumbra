import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// `JavaUnresolvedTypeInspection`: a type name the file neither declares nor imports reports
/// only when no known type bears it. Names that resolve without an import (`java.lang`, the
/// file's own package), names one import away (auto-import owns those), and package qualifier
/// segments never report.
final class JavaUnresolvedTypeInspectionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-unresolved-type-\(UUID().uuidString)", isDirectory: true)
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
        let walker = JavaSemanticWalker(tree: tree, source: source)
        XCTAssertTrue(walker.run())
        let all = await JavaUnresolvedTypeInspection.inspect(source: source, url: url, index: index, walker: walker)
        return all.filter { $0.id == "unresolved-type" }
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

    func testUnknownTypeReports() async throws {
        let found = try await findings("class T { UnknownType value; }")
        XCTAssertEqual(found.map(\.message), ["Cannot resolve type 'UnknownType'"])
    }

    func testQualifiedUnknownLastSegmentReports() async throws {
        let found = try await findings("class T { unknown.UnknownType value; }")
        XCTAssertEqual(found.map(\.message), ["Cannot resolve type 'UnknownType'"])
    }

    // MARK: - Silent

    func testJavaLangIsImplicitlyImported() async throws {
        // `java.lang` silence needs a JDK in the index: with no index at all the rule cannot
        // know `String` is implicit, and reports it like any other unknown name.
        let javaLang = [
            "package java.lang; public class String { }",
            "package java.lang; public class Integer { }",
        ]
        let found = try await findings("class T { String name; Integer count; }", libraries: javaLang)
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testSamePackageResolvesWithoutImport() async throws {
        let found = try await findings(
            "package com.example; class T { Helper helper; }",
            libraries: ["package com.example; public class Helper { }"]
        )
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testImportableNameIsAutoImportTerritory() async throws {
        let found = try await findings(
            "package com.example; class T { Helper helper; }",
            libraries: ["package com.other; public class Helper { }"]
        )
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testPackageQualifierSegmentsNeverReport() async throws {
        let found = try await findings(
            "package com.example; class T { java.io.OutputStream out; }",
            libraries: ["package java.io; public class OutputStream { }"]
        )
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testQualifiedButUnknownPackageSegmentNeverReports() async throws {
        // `unknown` names no type, but resolving qualifiers is name resolution's job (Phase 4),
        // not this rule's: only the unresolvable last segment reports.
        let found = try await findings("class T { unknown.Known value; }")
        XCTAssertEqual(found.map(\.message), ["Cannot resolve type 'Known'"])
    }

    // MARK: - `var`

    func testVarLocalIsSilent() async throws {
        let found = try await findings("class T { void m() { var x = 1; } }")
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testVarEnhancedForIsSilent() async throws {
        let found = try await findings("class T { void m(int[] xs) { for (var s : xs) { } } }")
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testVarTryWithResourcesIsSilent() async throws {
        let found = try await findings(
            "class T { static class R { } R open() { return null; } void m() { try (var r = open()) { } } }"
        )
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testVarLambdaParameterIsSilent() async throws {
        let found = try await findings(
            "class T { void m() { Runnable x = (var a) -> { }; } }",
            libraries: ["package java.lang; public interface Runnable { void run(); }"]
        )
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testVarLocalOfKnownTypeIsSilent() async throws {
        let found = try await findings(
            "import java.text.DecimalFormat; class T { void m() { var df = new DecimalFormat(\"#,##0\"); } }",
            libraries: ["package java.text; public class DecimalFormat { public DecimalFormat(String pattern) { } }"]
        )
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testVarFieldTypeStillReports() async throws {
        let found = try await findings("class T { var x; }")
        XCTAssertEqual(found.map(\.message), ["Cannot resolve type 'var'"])
    }

    func testVarMethodParameterStillReports() async throws {
        let found = try await findings("class T { void m(var x) { } }")
        XCTAssertEqual(found.map(\.message), ["Cannot resolve type 'var'"])
    }
}
