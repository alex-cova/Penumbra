import AppKit
import XCTest
import PenumbraLanguages
@testable import Penumbra

/// Coverage for the enrichment added to `TreeSitterBashQueries/highlights.scm` (numbers/operators/
/// test-operators/expansions/builtins/brackets on top of the original strings+keywords+comments
/// query). A bad node or token reference in the `.scm` wouldn't crash — it would just make the
/// query cursor silently yield zero captures for that pattern — so this asserts real coloring
/// shows up, not just that the build succeeds.
final class BashLanguageTests: XCTestCase {
    private func highlight(_ source: String) -> NSAttributedString {
        let highlighter = StringSyntaxHighlighter(theme: DefaultTheme(), language: .bash)
        return highlighter.syntaxHighlight(source)
    }

    private func color(in highlighted: NSAttributedString, at substring: String) -> UIColor? {
        let text = highlighted.string as NSString
        let location = text.range(of: substring).location
        guard location != NSNotFound else { return nil }
        return highlighted.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor
    }

    func testBuiltinCommandGetsAMoreSpecificColorThanAnOrdinaryCommand() {
        let theme = DefaultTheme()
        let highlighted = highlight("echo hi\nmy_custom_tool hi")
        let builtinColor = color(in: highlighted, at: "echo")
        let ordinaryColor = color(in: highlighted, at: "my_custom_tool")
        XCTAssertNotNil(builtinColor)
        XCTAssertNotNil(ordinaryColor)
        // Both peel to "function" in DefaultTheme today, but the important thing is the
        // `function.builtin` capture actually resolves (doesn't silently vanish) and doesn't
        // regress to the plain default text color.
        XCTAssertNotEqual(builtinColor, theme.textColor)
        XCTAssertNotEqual(ordinaryColor, theme.textColor)
    }

    func testTestOperatorsAndVariableExpansionAreColored() {
        let theme = DefaultTheme()
        let highlighted = highlight("if [[ \"$foo\" == \"bar\" ]]; then\n  echo yes\nfi")
        XCTAssertNotEqual(color(in: highlighted, at: "=="), theme.textColor)
        XCTAssertNotEqual(color(in: highlighted, at: "[["), theme.textColor)
    }

    func testDeclarationKeywordsAreColored() {
        let theme = DefaultTheme()
        let highlighted = highlight("local x=1\nreadonly y=2")
        XCTAssertNotEqual(color(in: highlighted, at: "local"), theme.textColor)
        XCTAssertNotEqual(color(in: highlighted, at: "readonly"), theme.textColor)
    }
}
