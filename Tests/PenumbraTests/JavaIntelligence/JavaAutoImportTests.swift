import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaAutoImportTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-auto-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAUniqueClassIsImported() async throws {
        let index = try await makeIndex(sources: [
            ("java/util/ArrayList.java", "package java.util; public class ArrayList { }")
        ])
        let source = "class T { ArrayList names; }\n"
        let edits = await JavaAutoImport.edits(in: source, index: index, policy: .intellij, caretUTF16: nil)
        XCTAssertEqual(apply(edits, to: source), "import java.util.ArrayList;\n\nclass T { ArrayList names; }\n")
    }

    func testListIsNotImportedWhenBothPackagesDefineIt() async throws {
        let index = try await makeIndex(sources: [
            ("java/util/List.java", "package java.util; public class List { }"),
            ("java/awt/List.java", "package java.awt; public class List { }")
        ])
        let source = "class T { List names; }\n"
        let edits = await JavaAutoImport.edits(in: source, index: index, policy: .intellij, caretUTF16: nil)
        XCTAssertTrue(edits.isEmpty)
    }

    func testAnExcludedPackageIsNotImported() async throws {
        let index = try await makeIndex(sources: [
            ("java/awt/List.java", "package java.awt; public class List { }")
        ])
        let source = "class T { List names; }\n"
        let policy = JavaImportPolicy(excluded: ["java.awt"])
        let edits = await JavaAutoImport.edits(in: source, index: index, policy: policy, caretUTF16: nil)
        XCTAssertTrue(edits.isEmpty)
    }

    func testTheNameUnderTheCaretIsLeftAlone() async throws {
        let index = try await makeIndex(sources: [
            ("java/util/ArrayList.java", "package java.util; public class ArrayList { }")
        ])
        let source = "class T { ArrayList names; }\n"
        let caret = (source as NSString).range(of: "ArrayList").location + 3
        let edits = await JavaAutoImport.edits(in: source, index: index, policy: .intellij, caretUTF16: caret)
        XCTAssertTrue(edits.isEmpty)
    }

    func testStringAndASamePackageTypeAreNotImported() async throws {
        let index = try await makeIndex(sources: [
            ("java/lang/String.java", "package java.lang; public class String { }"),
            ("demo/Helper.java", "package demo; public class Helper { }")
        ])
        let source = "package demo;\nclass T { String s; Helper h; }\n"
        let edits = await JavaAutoImport.edits(in: source, index: index, policy: .intellij, caretUTF16: nil)
        XCTAssertTrue(edits.isEmpty)
    }

    func testACollidingSimpleNameIsNotImported() async throws {
        let index = try await makeIndex(sources: [
            ("java/util/Date.java", "package java.util; public class Date { }"),
            ("java/sql/Date.java", "package java.sql; public class Date { }")
        ])
        let source = "import java.sql.*;\nclass T { Date d; }\n"
        let edits = await JavaAutoImport.edits(in: source, index: index, policy: .intellij, caretUTF16: nil)
        XCTAssertTrue(edits.isEmpty)
    }

    func testOnTheFlyOffInsertsNothing() async throws {
        let index = try await makeIndex(sources: [
            ("java/util/ArrayList.java", "package java.util; public class ArrayList { }")
        ])
        let source = "class T { ArrayList names; }\n"
        let policy = JavaImportPolicy(addUnambiguousImportsOnTheFly: false)
        let edits = await JavaAutoImport.edits(in: source, index: index, policy: policy, caretUTF16: nil)
        XCTAssertTrue(edits.isEmpty)
    }

    func testPasteImportsOnlyNamesInTheInsertedText() async throws {
        let index = try await makeIndex(sources: [
            ("java/util/ArrayList.java", "package java.util; public class ArrayList { }"),
            ("java/util/HashMap.java", "package java.util; public class HashMap { }")
        ])
        let source = "class T {\n    HashMap map;\n    ArrayList names;\n}\n"
        let edits = await JavaAutoImport.edits(
            forPastedText: "ArrayList names;", in: source, index: index, policy: .intellij
        )
        let result = apply(edits, to: source)
        XCTAssertTrue(result.contains("import java.util.ArrayList;"))
        XCTAssertFalse(result.contains("HashMap;"))
    }

    func testPasteOffInsertsNothing() async throws {
        let index = try await makeIndex(sources: [
            ("java/util/ArrayList.java", "package java.util; public class ArrayList { }")
        ])
        let source = "class T { ArrayList names; }\n"
        let policy = JavaImportPolicy(insertImportsOnPaste: .never)
        let edits = await JavaAutoImport.edits(forPastedText: "ArrayList names;", in: source, index: index, policy: policy)
        XCTAssertTrue(edits.isEmpty)
    }

    func testTypeNamesSkipAQualifier() {
        XCTAssertEqual(JavaAutoImport.typeNames(in: "java.util.ArrayList"), [])
        XCTAssertEqual(JavaAutoImport.typeNames(in: "ArrayList<String>"), ["ArrayList", "String"])
    }

    func testReplacingAStarRestoresTheUsedClasses() async throws {
        let index = try await makeIndex(sources: [
            ("java/util/List.java", "package java.util; public class List { }"),
            ("java/util/Map.java", "package java.util; public class Map { }")
        ])
        let source = "import java.util.*;\n\nclass T { List<String> a; Map<String, String> b; }\n"
        let caret = (source as NSString).range(of: "java.util.*").location
        let edits = await JavaAutoImport.expandStarEdits(in: source, caretUTF16: caret, index: index, policy: .intellij)
        XCTAssertEqual(
            apply(edits, to: source),
            "import java.util.List;\nimport java.util.Map;\n\nclass T { List<String> a; Map<String, String> b; }\n"
        )
    }

    func testAnAmbiguousNameRefusesToExpandAStar() async throws {
        let index = try await makeIndex(sources: [
            ("java/util/List.java", "package java.util; public class List { }"),
            ("java/awt/List.java", "package java.awt; public class List { }")
        ])
        let source = "import java.util.*;\n\nclass T { List names; }\n"
        let caret = (source as NSString).range(of: "*").location
        let edits = await JavaAutoImport.expandStarEdits(in: source, caretUTF16: caret, index: index, policy: .intellij)
        XCTAssertTrue(edits.isEmpty)
    }

    private func makeIndex(sources: [(path: String, source: String)]) async throws -> JavaIndex {
        var stubs: [JavaClassStub] = []
        for (path, source) in sources {
            let url = scratch.appendingPathComponent("src/\(path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: url, atomically: true, encoding: .utf8)
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: url).classes)
        }
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        return index
    }

    private func apply(_ edits: [TextEdit], to source: String) -> String {
        var result = source as NSString
        for edit in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(
                location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset
            )
            result = result.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return result as String
    }
}
