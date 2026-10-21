@preconcurrency import AppKit
import TestTreeSitterLanguages
import XCTest
@testable import Penumbra

/// Move Caret to Code Block Start / End finds the braces of the block around the caret.
@MainActor
final class CodeBlockNavigatorTests: XCTestCase {
    private let source = """
    class Widget {
      render(items) {
        if (items) {
          use("}");
        }
      }
    }
    """

    private func node(at location: Int, in text: String) throws -> TreeSitterNode {
        let mode = LanguageModeFactory.javaScriptLanguageMode(text: text)
        let before = (text as NSString).substring(to: location)
        let lines = before.components(separatedBy: "\n")
        let position = LinePosition(row: lines.count - 1, column: (lines.last ?? "").utf16.count)
        return try XCTUnwrap(mode.treeSitterNode(at: position))
    }

    private func offset(of needle: String, occurrence: Int = 0) -> Int {
        var range = NSRange(location: 0, length: 0)
        var searchFrom = 0
        for _ in 0...occurrence {
            range = (source as NSString).range(of: needle, range: NSRange(location: searchFrom, length: (source as NSString).length - searchFrom))
            searchFrom = range.upperBound
        }
        XCTAssertNotEqual(range.location, NSNotFound, "\(needle) is not in the source")
        return range.location == NSNotFound ? 0 : range.location
    }

    func testStartIsTheInnermostOpeningBraceBeforeTheCaret() throws {
        let caret = offset(of: "use(")
        let ifBrace = offset(of: "{", occurrence: 2)
        XCTAssertEqual(CodeBlockNavigator.target(from: caret, toEnd: false, startingAt: try node(at: caret, in: source)), ifBrace)
    }

    func testStartAgainMovesOutToTheNextBlock() throws {
        let ifBrace = offset(of: "{", occurrence: 2)
        let methodBrace = offset(of: "{", occurrence: 1)
        XCTAssertEqual(
            CodeBlockNavigator.target(from: ifBrace, toEnd: false, startingAt: try node(at: ifBrace, in: source)),
            methodBrace
        )
    }

    func testEndIsJustAfterTheInnermostClosingBrace() throws {
        let caret = offset(of: "use(")
        // The `}` in the string literal is not a brace of the block: the real one is on the next line.
        let closing = offset(of: "}\n  }\n}")
        XCTAssertEqual(
            CodeBlockNavigator.target(from: caret, toEnd: true, startingAt: try node(at: caret, in: source)),
            closing + 1
        )
    }

    func testEndAgainMovesOutToTheNextBlock() throws {
        let closing = offset(of: "}\n  }\n}")
        let afterIf = closing + 1
        let afterMethod = offset(of: "}\n}") + 1
        XCTAssertEqual(
            CodeBlockNavigator.target(from: afterIf, toEnd: true, startingAt: try node(at: afterIf - 1, in: source)),
            afterMethod
        )
    }

    func testNothingAroundTheCaretAtTheTopLevel() throws {
        let text = "const a = 1;\n"
        XCTAssertNil(CodeBlockNavigator.target(from: 3, toEnd: false, startingAt: try node(at: 3, in: text)))
        XCTAssertNil(CodeBlockNavigator.target(from: 3, toEnd: true, startingAt: try node(at: 3, in: text)))
    }
}
