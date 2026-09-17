import XCTest
import TestTreeSitterLanguages
@testable import Penumbra

/// Exercises ``DeclarationScanner`` against real tree-sitter-javascript trees (the grammar bundled
/// for tests). TypeScript-only node types are covered by ``LanguageConfigurationTests`` as data.
final class DeclarationScannerTests: XCTestCase {
    private func scan(_ text: String, configuration: LanguageConfiguration = .javaScript) -> [ScannedDeclaration] {
        let mode = LanguageModeFactory.javaScriptLanguageMode(text: text)
        guard let root = mode.rootSyntaxNode else {
            XCTFail("No root node")
            return []
        }
        return DeclarationScanner.scan(root: root, configuration: configuration, text: text as NSString)
    }

    func testFindsTopLevelFunctionAndClass() {
        let text = """
        function greet(name) {
            return "hi " + name;
        }

        class Person {
        }
        """
        let declarations = scan(text)
        let functions = declarations.filter { $0.kind == .function }
        let types = declarations.filter { $0.kind == .type }
        XCTAssertEqual(functions.map(\.name), ["greet"])
        XCTAssertEqual(types.map(\.name), ["Person"])
        XCTAssertEqual(functions.first?.depth, 0)
        XCTAssertEqual(types.first?.depth, 0)
    }

    func testNestedMethodHasDepthAndContainerSpansBody() {
        let text = """
        class Person {
            greet() {
                return 1;
            }
        }
        """
        let declarations = scan(text)
        guard let method = declarations.first(where: { $0.kind == .function }) else {
            return XCTFail("Expected a method")
        }
        XCTAssertEqual(method.name, "greet")
        XCTAssertEqual(method.depth, 1)
        // Container starts on the method's row and spans more than one row (the body).
        XCTAssertEqual(method.container.startRow, 1)
        XCTAssertGreaterThan(method.container.endRow, method.container.startRow)
        // Name span is inside the container span.
        XCTAssertGreaterThanOrEqual(method.name_span.startUTF16, method.container.startUTF16)
        XCTAssertLessThanOrEqual(method.name_span.endUTF16, method.container.endUTF16)
    }

    func testMethodSeparatorAnchorsForEachDeclaration() {
        let text = """
        class C {
            a() {}
            b() {}
        }
        """
        let anchorRows = Set(scan(text).filter { $0.isMethodSeparatorAnchor }.map { $0.container.startRow })
        // Rows: 0 = class, 1 = a(), 2 = b().
        XCTAssertTrue(anchorRows.contains(0))
        XCTAssertTrue(anchorRows.contains(1))
        XCTAssertTrue(anchorRows.contains(2))
    }

    func testNoNameWhenTextIsNil() {
        let mode = LanguageModeFactory.javaScriptLanguageMode(text: "function f() {}")
        let declarations = DeclarationScanner.scan(root: mode.rootSyntaxNode!, configuration: .javaScript, text: nil)
        XCTAssertEqual(declarations.first?.kind, .function)
        XCTAssertEqual(declarations.first?.name, "")
    }

    func testEmptyDeclarationsForConfigurationWithNoRules() {
        let empty = LanguageConfiguration(declarations: [])
        XCTAssertTrue(scan("function f() {}", configuration: empty).isEmpty)
    }
}
