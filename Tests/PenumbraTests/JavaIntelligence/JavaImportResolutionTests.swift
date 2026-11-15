import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// `unresolved-import` judges each import by its qualified identity (JLS 7.5): a single-type
/// import names a type, an on-demand import a package or type, a static import a type and one of
/// its static members. Another class sharing the simple name never makes an import valid.
final class JavaImportResolutionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-imports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private static let jdk = [
        "package java.lang; public class Object { }",
        "package java.lang; public final class String { }",
        "package java.util; public interface List<E> { }",
        "package java.util; public interface Map<K, V> { interface Entry<K, V> { } }",
        "package java.util; public class Collections { public static <T> List<T> emptyList() { return null; } public static final Object EMPTY = null; private static void hidden() { } }",
    ]

    private static let project = [
        "package com.acme; public class List { }",
        "package lib; class Hidden { }",
        "package lib; public class Visible { private static class Secret { } public static class Open { } }",
        "package p; public class Super { public static final int CONST = 1; public static class Inherited { } }",
        "package p; public class Sub extends Super { }",
        "package q; public class Open extends unindexed.Base { }",
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

    private func findings(_ source: String, package: String = "app") async throws -> [String] {
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 3, reader: try shard(Self.jdk)),
            .init(precedence: 1, reader: try shard(Self.project)),
        ])
        let service = JavaInspectionService(index: index, enabledRules: [.unresolvedImport], idleDelay: .zero)
        let url = scratch.appendingPathComponent("T.java")
        let text = "package \(package);\n" + source + "\nclass T { }\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let doc = Document(
            url: url, displayName: "T.java", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        await service.analyzeNow(doc)
        return await service.diagnostics(for: doc).map(\.message).sorted()
    }

    // MARK: - Single-type imports: identity, not simple name

    func testAnotherPackagesClassOfTheSameNameDoesNotValidateAnImport() async throws {
        let found = try await findings("import com.fake.List;")
        XCTAssertEqual(found, ["Cannot resolve import 'com.fake.List'"], "java.util.List and com.acme.List exist; com.fake.List does not")
    }

    func testSameNameInTwoRealPackagesBothResolve() async throws {
        let javaUtil = try await findings("import java.util.List;")
        let acme = try await findings("import com.acme.List;")
        XCTAssertEqual(javaUtil, [])
        XCTAssertEqual(acme, [])
    }

    func testNestedTypeImports() async throws {
        let found = try await findings("import java.util.Map.Entry;\nimport java.util.Map.Missing;")
        XCTAssertEqual(found, ["Cannot resolve import 'java.util.Map.Missing'"])
    }

    func testInheritedMemberTypeImportResolves() async throws {
        let found = try await findings("import p.Sub.Inherited;")
        XCTAssertEqual(found, [])
    }

    // MARK: - Accessibility

    func testPackagePrivateClassFromAnotherPackageIsReported() async throws {
        let found = try await findings("import lib.Hidden;")
        XCTAssertEqual(found, ["'lib.Hidden' is not public in 'lib'; cannot be accessed from outside package"])
    }

    func testPackagePrivateClassFromItsOwnPackageResolves() async throws {
        let found = try await findings("import lib.Hidden;", package: "lib")
        XCTAssertEqual(found, [])
    }

    func testPrivateNestedTypeIsReported() async throws {
        let found = try await findings("import lib.Visible.Secret;\nimport lib.Visible.Open;")
        XCTAssertEqual(found, ["'lib.Visible.Secret' has private access in 'lib.Visible'"])
    }

    // MARK: - On-demand imports

    func testOnDemandImportOfAMissingPackageIsReported() async throws {
        let found = try await findings("import java.util.*;\nimport com.nowhere.*;\nimport java.util.Map.*;")
        XCTAssertEqual(found, ["Cannot resolve import 'com.nowhere.*'"])
    }

    // MARK: - Static imports

    func testStaticMemberImportsResolveByMember() async throws {
        let found = try await findings("""
        import static java.util.Collections.emptyList;
        import static java.util.Collections.EMPTY;
        import static java.util.Collections.*;
        import static java.util.Map.Entry;
        import static p.Sub.CONST;
        """)
        XCTAssertEqual(found, [], "a static member is not a class: its name must not be looked up as one")
    }

    func testMissingStaticMembersAndOwnersAreReported() async throws {
        let found = try await findings("""
        import static java.util.Collections.noSuchMethod;
        import static java.util.Collections.hidden;
        import static com.fake.Util.*;
        import static com.fake.Util.run;
        """)
        XCTAssertEqual(found, [
            "Cannot resolve import 'com.fake.Util.*'",
            "Cannot resolve import 'com.fake.Util.run'",
            "Cannot resolve static member 'hidden' in 'java.util.Collections'",
            "Cannot resolve static member 'noSuchMethod' in 'java.util.Collections'",
        ])
    }

    /// `q.Open` extends a class the index does not have: its inherited statics are unknown, so a
    /// member it does not declare is not provably missing.
    func testStaticMemberOfAnOpenHierarchyIsNotJudged() async throws {
        let found = try await findings("import static q.Open.SOMETHING;")
        XCTAssertEqual(found, [])
    }
}

/// One import error, one row: a fresh `javac` key for any of the ways an import fails drops the
/// inspection finding on the same line.
final class JavaImportMergerTests: XCTestCase {
    private func diagnostic(_ code: String, line: Int) -> Diagnostic {
        let position = TextPosition(line: line, column: 0, utf16Offset: 0)
        return Diagnostic(id: UUID(), severity: .warning, message: code, range: TextRange(start: position, end: position), source: "t", code: code)
    }

    func testImportFindingsYieldToEachJavacImportKey() {
        for key in ["compiler.err.doesnt.exist", "compiler.err.not.def.public.cant.access", "compiler.err.report.access", "compiler.err.cant.resolve.location"] {
            let kept = JavaDiagnosticsMerger.filter(
                inspections: [diagnostic("unresolved-import", line: 1)],
                javac: [diagnostic("javac:\(key)", line: 1)], fresh: true
            )
            XCTAssertEqual(kept.count, 0, key)
        }
        let unrelated = JavaDiagnosticsMerger.filter(
            inspections: [diagnostic("unresolved-import", line: 1)],
            javac: [diagnostic("javac:compiler.err.doesnt.exist", line: 2)], fresh: true
        )
        XCTAssertEqual(unrelated.count, 1, "another line's error suppresses nothing")
    }
}
