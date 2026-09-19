@preconcurrency import AppKit
import XCTest
@testable import Penumbra

final class SyntaxHighlightApplyTests: XCTestCase {
    func testTraitOnlyTokensAreKept() {
        let token = TreeSitterSyntaxHighlightToken(
            range: NSRange(location: 0, length: 4),
            textColor: nil,
            shadow: nil,
            font: nil,
            fontTraits: .bold
        )
        XCTAssertFalse(token.isEmpty, "markup.bold/italic have no color; dropping them silently skipped emphasis")
    }

    func testNestedTokenInheritsEnclosingFont() {
        let body = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let heading = NSFont.monospacedSystemFont(ofSize: 21, weight: .regular)
        // `**bold**` inside `# heading`: the bold token has no font of its own and must derive from the
        // heading's size, not snap back to the body font.
        XCTAssertTrue(TreeSitterSyntaxHighlighter.baseFont(tokenFont: nil, currentFont: heading, defaultFont: body) === heading)
        // A token that carries its own font wins.
        XCTAssertTrue(TreeSitterSyntaxHighlighter.baseFont(tokenFont: heading, currentFont: body, defaultFont: body) === heading)
        // Ordinary code: nothing applied yet, so the default font is used.
        XCTAssertTrue(TreeSitterSyntaxHighlighter.baseFont(tokenFont: nil, currentFont: nil, defaultFont: body) === body)
    }

    func testAdjacentSameStyleTokensMerge() {
        let color = NSColor.red
        let first = TreeSitterSyntaxHighlightToken(
            range: NSRange(location: 0, length: 2),
            textColor: color,
            shadow: nil,
            font: nil,
            fontTraits: []
        )
        let second = TreeSitterSyntaxHighlightToken(
            range: NSRange(location: 2, length: 3),
            textColor: color,
            shadow: nil,
            font: nil,
            fontTraits: []
        )
        XCTAssertTrue(first.hasSameStyle(as: second))
        let merged = first.merging(second)
        XCTAssertEqual(merged.range, NSRange(location: 0, length: 5))
        XCTAssertTrue(merged.textColor === color)
    }

    func testParagraphStylesAreInternedByTabWidth() {
        let font = NSFont.systemFont(ofSize: 12)
        let color = NSColor.textColor
        let first = NSMutableAttributedString(string: "a")
        let second = NSMutableAttributedString(string: "bb")
        DefaultStringAttributes(textColor: color, font: font, kern: 0, tabWidth: 28).apply(to: first)
        DefaultStringAttributes(textColor: color, font: font, kern: 0, tabWidth: 28).apply(to: second)
        let styleA = first.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as AnyObject?
        let styleB = second.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as AnyObject?
        XCTAssertTrue(styleA === styleB, "rebuilding 20 NSTextTab objects per line is wasted work")
    }
}
