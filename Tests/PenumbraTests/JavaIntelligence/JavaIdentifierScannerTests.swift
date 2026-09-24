import XCTest
@testable import JavaIntelligence

final class JavaIdentifierScannerTests: XCTestCase {
    private func ids(_ source: String) -> Set<String> {
        JavaIdentifierScanner.identifiers(in: source)
    }

    func testCollectsIdentifiersAndKeywords() {
        let found = ids("package a.b; public class Foo { int $x_1 = bar(baz); }")
        XCTAssertTrue(found.isSuperset(of: ["package", "a", "b", "Foo", "$x_1", "bar", "baz", "int"]))
    }

    func testSkipsLineAndBlockComments() {
        let found = ids("""
        // hidden1
        int a; /* hidden2
        still hidden3 */ int b; /** javadoc hidden4 */
        """)
        XCTAssertEqual(found, ["int", "a", "b"])
    }

    func testSkipsStringAndCharLiterals() {
        let found = ids(#"String s = "hidden \" still hidden"; char c = '"'; char d = '\''; int after;"#)
        XCTAssertFalse(found.contains("hidden"))
        XCTAssertFalse(found.contains("still"))
        XCTAssertTrue(found.contains("after"))
        XCTAssertTrue(found.contains("s"))
    }

    func testSkipsTextBlocks() {
        let found = ids("String t = \"\"\"\n  hidden \"quoted\" \\\"\"\" text\n  \"\"\"; int visible;")
        XCTAssertFalse(found.contains("hidden"))
        XCTAssertFalse(found.contains("text"))
        XCTAssertTrue(found.contains("visible"))
    }

    func testCommentMarkersInsideStringsDoNotStartComments() {
        let found = ids(#"String u = "http://x"; int visible;"#)
        XCTAssertTrue(found.contains("visible"))
        XCTAssertFalse(found.contains("http"))
    }

    func testNumericLiteralsAreNotIdentifiers() {
        let found = ids("long a = 0xFFL; double b = 1e3f; int c = 10;")
        XCTAssertFalse(found.contains("xFFL"))
        XCTAssertFalse(found.contains("e3f"))
        XCTAssertTrue(found.isSuperset(of: ["a", "b", "c"]))
    }

    func testUnicodeIdentifiers() {
        XCTAssertTrue(ids("int größe = 1; int 名前;").isSuperset(of: ["größe", "名前"]))
    }

    func testUnterminatedStringEndsAtLineBreak() {
        XCTAssertTrue(ids("String s = \"oops\nint next;").contains("next"))
    }

    func testContains() {
        XCTAssertTrue(JavaIdentifierScanner.contains("Foo", in: "new Foo();"))
        XCTAssertFalse(JavaIdentifierScanner.contains("Foo", in: "// Foo\n\"Foo\""))
    }
}
