import XCTest
@testable import JavaIntelligence

/// `JavaRoleExtractor`: every identifier occurrence in a parsed file gets the roles the usage
/// search narrows on, mirroring `JavaReferenceClassifier` (whatever the classifier can turn
/// into a match has a role; `this`/`super` and package segments have none).
final class JavaIdentifierRoleTests: XCTestCase {
    private func roles(in source: String) throws -> [String: JavaIdentifierRoles] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        return JavaRoleExtractor.roles(in: tree)
    }

    private static let source = """
        package p;
        import java.util.List;
        import static com.acme.Util.helper;
        class A {
            int size;
            int get() { return size; }
            void go(A other, List<String> items) {
                int n = other.get();
                items.add("x");
                String s = Util.helper("y");
                Runnable r = this::go;
            }
        }
        """

    func testCallMemberAndTypePositions() throws {
        let found = try roles(in: Self.source)
        XCTAssertEqual(found["get"], [.declared, .call])
        XCTAssertEqual(found["add"], [.call])
        XCTAssertEqual(found["go"], [.declared, .member])
        XCTAssertEqual(found["size"], [.declared, .plain])
        XCTAssertEqual(found["other"], [.declared, .plain])
        XCTAssertEqual(found["String"], [.typeName])
        XCTAssertEqual(found["A"], [.declared, .typeName])
        XCTAssertEqual(found["List"], [.imported, .typeName])
    }

    func testImportsAndPackages() throws {
        let found = try roles(in: Self.source)
        XCTAssertEqual(found["helper"], [.call, .imported])
        XCTAssertEqual(found["Util"], [.imported, .plain])
        XCTAssertEqual(found["java"], [.imported])
        XCTAssertEqual(found["com"], [.imported], "every import segment can resolve the import")
        XCTAssertEqual(found["acme"], [.imported])
        XCTAssertNil(found["p"], "package segments are never usages")
    }

    func testStringsCommentsAndKeywordsHaveNoRoles() throws {
        let found = try roles(in: Self.source)
        XCTAssertNil(found["x"])
        XCTAssertNil(found["y"])
        XCTAssertNil(found["int"])
        XCTAssertNil(found["void"])
        XCTAssertNil(found["this"])
        XCTAssertEqual(found["n"], [.declared], "an unread local is declaration-only")
    }

    func testEnumConstantsAndCaseLabels() throws {
        let found = try roles(in: """
            enum Color {
                RED, GREEN;
                static String name(Color c) {
                    switch (c) { case RED: return "r"; default: return "?"; }
                }
            }
            """)
        XCTAssertEqual(found["RED"], [.declared, .plain])
        XCTAssertEqual(found["GREEN"], [.declared])
        XCTAssertEqual(found["Color"], [.declared, .typeName])
        XCTAssertEqual(found["name"], [.declared])
    }
}
