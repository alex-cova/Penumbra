@preconcurrency import AppKit
import PenumbraMarkdownLanguage
import XCTest
@testable import Penumbra

/// Sticky lines in Markdown pin the `#`, `##` and `###` headings whose section is being scrolled.
@MainActor
final class MarkdownStickyLinesTests: XCTestCase {
    // Rows: 0 `# Guide`, 1 blank, 2 intro, 3 blank, 4 `## Install`, 5 blank, 6 steps, 7 blank,
    // 8 `### macOS`, 9 blank, 10 brew, 11 blank, 12 `#### Notes`, 13 blank, 14 note, 15 blank,
    // 16 `## Usage`, 17 blank, 18 usage text, 19 blank, 20 `# Appendix`, 21 blank, 22 appendix text
    private let document = """
    # Guide

    Intro text.

    ## Install

    Steps.

    ### macOS

    Use brew.

    #### Notes

    A note.

    ## Usage

    Run it.

    # Appendix

    More.
    """

    private func scopes(_ text: String, row: Int) throws -> [StickyScope] {
        let mode = makeMarkdownLanguageMode(text: text)
        let root = try XCTUnwrap(mode.rootSyntaxNode)
        return StickyScopeResolver.scopes(containingRow: row, root: root, configuration: .markdown)
    }

    private func makeMarkdownLanguageMode(text: String) -> TreeSitterInternalLanguageMode {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let mode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.markdown.internalLanguage,
            languageProvider: MarkdownLanguageProvider(),
            stringView: stringView,
            lineManager: lineManager)
        mode.parse()
        return mode
    }

    func testHeadingLevelsNestOutermostFirst() throws {
        let found = try scopes(document, row: 10)
        XCTAssertEqual(found.map(\.headerRow), [0, 4, 8])
    }

    func testSectionEndsAtTheNextHeadingOfTheSameOrAHigherLevel() throws {
        let found = try scopes(document, row: 10)
        XCTAssertEqual(found.map(\.endRow), [19, 15, 15], "`# Guide` runs to the row before `# Appendix`; `## Install` to the row before `## Usage`")
    }

    func testFourthLevelHeadingsAreNotPinned() throws {
        let found = try scopes(document, row: 14)
        XCTAssertEqual(found.map(\.headerRow), [0, 4, 8], "`#### Notes` stays out, its `###` parent stays")
    }

    func testSiblingSectionReplacesThePreviousOne() throws {
        XCTAssertEqual(try scopes(document, row: 18).map(\.headerRow), [0, 16])
        XCTAssertEqual(try scopes(document, row: 22).map(\.headerRow), [20])
    }

    func testRowOnTheHeadingItselfIsNotBelowIt() throws {
        XCTAssertEqual(try scopes(document, row: 4).map(\.headerRow), [0])
    }

    func testTextBeforeTheFirstHeadingHasNoScopes() throws {
        XCTAssertEqual(try scopes("Preface\n\nMore preface\n\n# Title\n\nBody", row: 2), [])
    }

    func testHashesInsideACodeFenceAreNotHeadings() throws {
        let text = "# Title\n\n```sh\n# a comment\necho hi\n```\n\nafter"
        XCTAssertEqual(try scopes(text, row: 4).map(\.headerRow), [0])
    }

    /// The grammar gives setext headings no extent (one flat `section` holds them all), so pinning
    /// them would keep the first one up for the whole document. They stay unpinned.
    func testSetextHeadingsAreNotPinned() throws {
        let text = "Title\n=====\n\nPart\n----\n\nBody\n\nMore"
        XCTAssertEqual(try scopes(text, row: 6), [])
        XCTAssertEqual(try scopes(text, row: 8), [])
    }

    func testSetextHeadingDoesNotPinUnderAnAtxSection() throws {
        let text = "# Top\n\nPart\n----\n\nBody\n\nMore"
        XCTAssertEqual(try scopes(text, row: 6).map(\.headerRow), [0])
    }

    func testHeadingsArePinnedInAScrolledTextView() {
        var lines = ["# Guide", "", "Intro.", "", "## Install", "", "### macOS", ""]
        lines += (0 ..< 80).map { "Line \($0) of the macOS instructions." }
        lines += ["", "## Usage", ""] + (0 ..< 40).map { "Usage \($0)." }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: lines.joined(separator: "\n"), theme: DefaultTheme(),
                                        language: .markdown, languageProvider: MarkdownLanguageProvider(),
                                        parsePolicy: .eager))
        textView.languageIdentifier = "markdown"
        textView.showsStickyLines = true
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)

        textView.contentOffset = CGPoint(x: 0, y: textView.stickyLinesInput.yPosition(ofRow: 40))
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.stickyLineHeaderRowsForTesting, [0, 4, 6])

        // Past the end of `### macOS` and `## Install`, `## Usage` replaces them under `# Guide`.
        textView.contentOffset = CGPoint(x: 0, y: textView.stickyLinesInput.yPosition(ofRow: 100))
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.stickyLineHeaderRowsForTesting, [0, 89])
    }

    /// A theme scales `markup.heading.1` to 1.6x; a pinned row is one editor line high, so the
    /// pinned text keeps the heading's look but not its size.
    func testPinnedHeadingTextIsNotLargerThanTheEditorFont() throws {
        let palette = ThemeCatalog.palette(id: "hextech-dark", fallbackDark: true)
        let theme = PaletteTheme(size: 13, palette: palette, postscriptName: "Menlo-Regular", markupStyle: .default)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: "# Big title\n\nBody\n", theme: theme, language: .markdown,
                                        languageProvider: MarkdownLanguageProvider(), parsePolicy: .eager))
        textView.languageIdentifier = "markdown"
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)

        // The theme does draw the heading larger, so the check below proves something.
        XCTAssertGreaterThan(try XCTUnwrap(theme.font(for: "markup.heading.1")).pointSize, theme.font.pointSize)

        let pinned = try XCTUnwrap(textView.stickyLinesInput.stickyLineContent(forRow: 0))
        XCTAssertEqual(pinned.string, "# Big title")
        XCTAssertEqual(Set(fontSizes(of: pinned)), [theme.font.pointSize])
    }

    /// The scrollbar preview rows have the same one-line height as pinned rows.
    func testScrollbarPreviewHeadingTextIsNotLargerThanTheEditorFont() throws {
        let palette = ThemeCatalog.palette(id: "hextech-dark", fallbackDark: true)
        let theme = PaletteTheme(size: 13, palette: palette, postscriptName: "Menlo-Regular", markupStyle: .default)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        textView.setState(TextViewState(text: "# Big title\n\nBody\n", theme: theme, language: .markdown,
                                        languageProvider: MarkdownLanguageProvider(), parsePolicy: .eager))
        textView.languageIdentifier = "markdown"
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)

        let content = try XCTUnwrap(textView.editorFragmentPreviewContentForTesting(anchorRow: 0))
        let heading = try XCTUnwrap(content.lines.first { $0.number == 1 })
        XCTAssertEqual(heading.text.string, "# Big title")
        XCTAssertEqual(Set(fontSizes(of: heading.text)), [theme.font.pointSize])
    }

    private func fontSizes(of text: NSAttributedString) -> [CGFloat] {
        var sizes: [CGFloat] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let font = value as? NSFont { sizes.append(font.pointSize) }
        }
        return sizes
    }

    func testMarkdownIsRegisteredWithItsSectionRule() {
        let configuration = LanguageConfigurationRegistry.builtIns.configuration(for: "markdown")
        XCTAssertNotNil(configuration.stickySection)
        XCTAssertNil(LanguageConfigurationRegistry.builtIns.configuration(for: "plain").stickySection)
    }
}
