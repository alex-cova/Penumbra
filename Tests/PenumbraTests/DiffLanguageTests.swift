import AppKit
import XCTest
import PenumbraLanguages
@testable import Penumbra

/// Coverage for the vendored `tree-sitter-diff` grammar: the query must at least compile
/// (a bad node/token reference in the `.scm` would otherwise fail silently — the query cursor
/// would just yield zero captures) and additions/deletions must resolve to distinct colors.
final class DiffLanguageTests: XCTestCase {
    private static let sampleDiff = """
    diff --git a/foo.txt b/foo.txt
    index 83db48f..bf269c4 100644
    --- a/foo.txt
    +++ b/foo.txt
    @@ -1,3 +1,3 @@
    -hello world
    +hello swift
     unchanged line
    """

    func testAdditionsAndDeletionsGetDistinctColors() {
        let highlighter = StringSyntaxHighlighter(theme: DefaultTheme(), language: .diff)
        let highlighted = highlighter.syntaxHighlight(Self.sampleDiff)

        let text = highlighted.string as NSString
        // Check inside the line content rather than at the leading "+"/"-" marker: the marker
        // itself additionally matches a `punctuation.special` capture (a shorter, more specific
        // range than the enclosing `(addition)`/`(deletion)` node) that intentionally overrides
        // `diff.plus`/`diff.minus` for that single character — matching how real diff themes
        // give the marker its own accent color distinct from the line's body.
        let minusLocation = text.range(of: "hello world").location
        let plusLocation = text.range(of: "hello swift").location
        XCTAssertNotEqual(minusLocation, NSNotFound)
        XCTAssertNotEqual(plusLocation, NSNotFound)

        let minusColor = highlighted.attribute(.foregroundColor, at: minusLocation, effectiveRange: nil) as? UIColor
        let plusColor = highlighted.attribute(.foregroundColor, at: plusLocation, effectiveRange: nil) as? UIColor
        XCTAssertNotNil(minusColor)
        XCTAssertNotNil(plusColor)
        XCTAssertNotEqual(minusColor, plusColor)
    }

    func testUnchangedContextLineFallsBackToDefaultTextColor() {
        let theme = DefaultTheme()
        let highlighter = StringSyntaxHighlighter(theme: theme, language: .diff)
        let highlighted = highlighter.syntaxHighlight(Self.sampleDiff)

        let text = highlighted.string as NSString
        let contextLocation = text.range(of: "unchanged line").location
        XCTAssertNotEqual(contextLocation, NSNotFound)

        let contextColor = highlighted.attribute(.foregroundColor, at: contextLocation, effectiveRange: nil) as? UIColor
        XCTAssertEqual(contextColor, theme.textColor)
    }
}
