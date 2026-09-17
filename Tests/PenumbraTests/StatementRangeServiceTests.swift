import Foundation
@testable import Penumbra
import TestTreeSitterLanguages
import TreeSitter
import XCTest

/// `StatementRangeService` climbs a tree-sitter node to the enclosing statement's row span,
/// which "Move Statement Up/Down" feeds into `MoveLinesService`.
final class StatementRangeServiceTests: XCTestCase {
    private let delegate = MockTreeSitterParserDelegate()
    /// Held for the test's lifetime — a `TreeSitterNode` is a raw pointer into this tree, and
    /// `TreeSitterTree.deinit` frees it.
    private var tree: TreeSitterTree?

    private func node(in source: NSString, row: Int, column: Int) -> TreeSitterNode {
        delegate.string = source
        let parser = TreeSitterParser(encoding: TSInputEncoding.treeSitterUTF16)
        parser.delegate = delegate
        parser.language = TreeSitterLanguagePointer(tree_sitter_javascript())
        tree = parser.parse(source)
        let point = TreeSitterTextPoint(row: UInt32(row), column: UInt32(column * 2))
        return tree!.rootNode.descendantForRange(from: point, to: point)
    }

    func testClimbsToMultiLineIfStatement() {
        let source: NSString = "const a = 1;\nif (x) {\n  y();\n}\nconst b = 2;\n"
        let range = StatementRangeService().statementRowRange(around: node(in: source, row: 1, column: 2))
        XCTAssertEqual(range, 1...3, "The whole if-block, not just its first line")
    }

    func testSingleLineStatementSpansOneRow() {
        let source: NSString = "const a = 1;\nconst b = 2;\n"
        let range = StatementRangeService().statementRowRange(around: node(in: source, row: 1, column: 4))
        XCTAssertEqual(range, 1...1)
    }

    func testNeverReturnsTheWholeProgram() {
        let source: NSString = "function outer() {\n  inner();\n}\n"
        let range = StatementRangeService().statementRowRange(around: node(in: source, row: 1, column: 3))
        XCTAssertNotNil(range)
        XCTAssertLessThanOrEqual(range!.upperBound, 2, "Not the trailing program row")
    }
}
