import Foundation
import LanguageSyntax
import XCTest
@testable import JavaIntelligence

/// `children` and `namedChildren` walk one cursor; `child(at:)` and `namedChild(at:)` are the
/// per-index access they replaced, and must agree with them.
final class SyntaxNodeChildrenTests: XCTestCase {
    func testChildrenMatchPerIndexAccess() throws {
        let source = """
        package a.b;
        import java.util.*;
        /** doc */
        public class A<T> extends B implements C {
            // comment
            int x = 1, y;
            A(int a) { this.x = a; }
            void m(String s, int... rest) { foo(s, 1 + 2); }
            enum E { ONE, TWO; int v; }
        }
        """
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        var pending = [tree.rootNode]
        var visited = 0
        while let node = pending.popLast() {
            visited += 1
            let byIndex = (0 ..< node.childCount).compactMap { node.child(at: $0) }
            XCTAssertEqual(node.children.map(\.byteRange), byIndex.map(\.byteRange), node.type)
            XCTAssertEqual(node.children.map(\.type), byIndex.map(\.type), node.type)
            let namedByIndex = (0 ..< node.namedChildCount).compactMap { node.namedChild(at: $0) }
            XCTAssertEqual(node.namedChildren.map(\.byteRange), namedByIndex.map(\.byteRange), node.type)
            XCTAssertEqual(node.namedChildren.map(\.type), namedByIndex.map(\.type), node.type)
            pending.append(contentsOf: byIndex)
        }
        XCTAssertGreaterThan(visited, 50)
    }

    func testFirstNamedChildOfType() throws {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse("package p; import a.B; import c.D; class K {}"))
        XCTAssertEqual(tree.rootNode.firstNamedChild(ofType: "import_declaration")?.text, "import a.B;")
        XCTAssertEqual(tree.rootNode.firstNamedChild(ofType: "class_declaration")?.text, "class K {}")
        XCTAssertNil(tree.rootNode.firstNamedChild(ofType: "interface_declaration"))
    }

    func testChildrenOfAClassWithThousandsOfMembersStayLinear() throws {
        let members = (0 ..< 3000).map { "    int field\($0);" }.joined(separator: "\n")
        let tree = try XCTUnwrap(JavaSyntaxParser().parse("class Big {\n\(members)\n}"))
        let body = try XCTUnwrap(tree.rootNode.namedChildren.first?.child(byFieldName: "body"))
        XCTAssertEqual(body.namedChildren.count, 3000)
        XCTAssertEqual(body.namedChildren.last?.text, "int field2999;")
    }
}
