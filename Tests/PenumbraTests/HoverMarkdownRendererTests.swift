import XCTest
import AppKit
@testable import Penumbra

@MainActor
final class HoverMarkdownRendererTests: XCTestCase {
    private func font(at index: Int, in text: NSAttributedString) -> NSFont? {
        text.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    func testCodeBlockKeepsItsLinesAndUsesTheMonospacedFont() {
        let text = HoverMarkdownRenderer.render("```java\npublic int size()\n```\n\nReturns the size.")
        XCTAssertEqual(text.string, "public int size()\nReturns the size.")
        XCTAssertEqual(font(at: 0, in: text)?.isFixedPitch, true)
        XCTAssertEqual(font(at: text.length - 1, in: text)?.isFixedPitch, false)
    }

    func testInlineMarkupBecomesFontTraitsAndDelimitersDisappear() {
        let text = HoverMarkdownRenderer.render("a **bold** and *slanted* and `code`")
        XCTAssertEqual(text.string, "a bold and slanted and code")
        let ns = text.string as NSString
        let bold = font(at: ns.range(of: "bold").location, in: text)
        XCTAssertEqual(bold?.fontDescriptor.symbolicTraits.contains(.bold), true)
        let slanted = font(at: ns.range(of: "slanted").location, in: text)
        XCTAssertEqual(slanted?.fontDescriptor.symbolicTraits.contains(.italic), true)
        XCTAssertEqual(font(at: ns.range(of: "code").location, in: text)?.isFixedPitch, true)
    }

    func testBulletsAndParagraphsAreSeparateLines() {
        let text = HoverMarkdownRenderer.render("**Parameters**\n- `a` — first\n- `b` — second\n\nAfter.")
        XCTAssertEqual(text.string, "Parameters\n•\ta — first\n•\tb — second\nAfter.")
    }

    func testPlainTextIsLeftAlone() {
        let text = HoverMarkdownRenderer.render("**not markdown**", isMarkdown: false)
        XCTAssertEqual(text.string, "**not markdown**")
    }

    func testSizeGrowsWithContentAndWrapsAtMaxWidth() {
        let short = HoverMarkdownRenderer.size(of: HoverMarkdownRenderer.render("Hi"), maxWidth: 400)
        let long = HoverMarkdownRenderer.size(of: HoverMarkdownRenderer.render(String(repeating: "word ", count: 200)), maxWidth: 400)
        XCTAssertLessThan(short.width, 100)
        XCTAssertEqual(long.width, 400, accuracy: 1)
        XCTAssertGreaterThan(long.height, short.height * 5)
    }
}
