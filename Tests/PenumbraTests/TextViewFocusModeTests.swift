import XCTest
@testable import Penumbra
import PenumbraMarkdownLanguage

@MainActor
final class TextViewFocusModeTests: XCTestCase {
    func testDefaultsAndAlphaClamping() {
        let textView = makeFocusedTextView(text: "Hello.")

        XCTAssertFalse(textView.isFocusModeEnabled)
        XCTAssertEqual(textView.focusGranularity, .paragraph)
        XCTAssertEqual(textView.unfocusedTextAlpha, 0.35)

        textView.unfocusedTextAlpha = -1
        XCTAssertEqual(textView.unfocusedTextAlpha, 0)
        textView.unfocusedTextAlpha = 2
        XCTAssertEqual(textView.unfocusedTextAlpha, 1)
    }

    func testParagraphFocusSpansLinesUntilBlankLine() {
        let text = "First line\nSecond line\n\nThird line"
        let textView = makeFocusedTextView(text: text)
        textView.focusGranularity = .paragraph
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 12, length: 0)

        XCTAssertEqual(textView.focusedRanges, [NSRange(location: 0, length: 22)])
        XCTAssertEqual(focusedText(in: textView), "First line\nSecond line")

        textView.selectedRange = NSRange(location: 25, length: 0)
        XCTAssertEqual(focusedText(in: textView), "Third line")
    }

    func testParagraphFocusTreatsCRLFAsOneDelimiter() {
        let textView = makeFocusedTextView(text: "One\r\nTwo")
        textView.focusGranularity = .paragraph
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 5, length: 0)

        XCTAssertEqual(textView.focusedRanges, [NSRange(location: 0, length: 8)])
    }

    func testParagraphFocusTreatsWhitespaceOnlyLineAsBlank() {
        let textView = makeFocusedTextView(text: "One\n  \t\nTwo")
        textView.focusGranularity = .paragraph
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 1, length: 0)

        XCTAssertEqual(focusedText(in: textView), "One")
    }

    func testSelectionAcrossParagraphsFocusesBothAndCollapsesBack() {
        let text = "One\ntwo\n\nThree\nfour\n\nFive"
        let textView = makeFocusedTextView(text: text)
        textView.focusGranularity = .paragraph
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 2, length: 10)

        XCTAssertEqual(textView.focusedRanges.count, 1)
        XCTAssertTrue(focusedText(in: textView).hasPrefix("One\ntwo"))
        XCTAssertTrue(focusedText(in: textView).hasSuffix("four"))
    }

    func testParagraphExpansionIsBoundedOnDocumentWithoutBlankLines() {
        let text = (0..<10_000).map { "line \($0)" }.joined(separator: "\n")
        let textView = makeFocusedTextView(text: text)
        textView.focusGranularity = .paragraph
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: (text as NSString).length / 2, length: 0)

        let lines = focusedText(in: textView).split(separator: "\n").count
        XCTAssertLessThanOrEqual(lines, 2 * TextSegmenter.maxParagraphLines + 1)
        XCTAssertGreaterThan(lines, 1)
    }

    func testSentenceFocusContinuesAcrossHardLineBreaks() {
        let text = "Intro sentence.\n\nFootnote reference inline, referencing a definition that appears\nbefore this paragraph, and more text. Next one."
        let textView = makeFocusedTextView(text: text)
        textView.focusGranularity = .sentence
        textView.isFocusModeEnabled = true

        textView.selectedRange = NSRange(location: (text as NSString).range(of: "definition").location, length: 0)
        XCTAssertEqual(
            focusedText(in: textView),
            "Footnote reference inline, referencing a definition that appears\nbefore this paragraph, and more text. "
        )
        textView.selectedRange = NSRange(location: (text as NSString).range(of: "and more").location, length: 0)
        XCTAssertTrue(focusedText(in: textView).hasPrefix("Footnote reference"))
    }

    func testSentenceFocusKeepsUTF16LengthForCRLFParagraph() {
        let text = "Alpha beta\r\ngamma delta. Second."
        let textView = makeFocusedTextView(text: text)
        textView.focusGranularity = .sentence
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 2, length: 0)

        XCTAssertEqual(focusedText(in: textView), "Alpha beta\r\ngamma delta. ")
    }

    func testFencedCodeBlockIsFocusedWholeInMarkdown() throws {
        let text = "Intro paragraph.\n\n```json\n{\n  \"a\": 1,\n  \"b\": 2\n}\n```\n\nAfter."
        let textView = makeFocusedTextView(text: text)
        textView.setState(TextViewState(text: text,
                                        theme: DefaultTheme(),
                                        language: .markdown,
                                        languageProvider: MarkdownLanguageProvider(),
                                        parsePolicy: .eager))
        textView.layoutIfNeeded()
        try XCTSkipUnless(textView.isSyntaxTreeReady, "markdown tree not ready")
        textView.isFocusModeEnabled = true

        let expected = "```json\n{\n  \"a\": 1,\n  \"b\": 2\n}\n```"
        for granularity in [FocusGranularity.paragraph, .sentence] {
            textView.focusGranularity = granularity
            textView.selectedRange = NSRange(location: (text as NSString).range(of: "\"b\"").location, length: 0)
            XCTAssertEqual(focusedText(in: textView), expected, "\(granularity)")
            textView.selectedRange = NSRange(location: (text as NSString).range(of: "```json").location, length: 0)
            XCTAssertEqual(focusedText(in: textView), expected, "\(granularity) at the opening fence")
        }

        textView.selectedRange = NSRange(location: (text as NSString).range(of: "After").location, length: 0)
        XCTAssertEqual(focusedText(in: textView), "After.")
    }

    func testSentenceFocusHandlesAbbreviationDecimalAndClosingQuote() {
        let text = "Dr. Smith paid 3.14. \"Done!\" Next."
        let textView = makeFocusedTextView(text: text)
        textView.focusGranularity = .sentence
        textView.isFocusModeEnabled = true

        textView.selectedRange = NSRange(location: 5, length: 0)
        XCTAssertEqual(focusedText(in: textView), "Dr. Smith paid 3.14. ")

        let doneLocation = (text as NSString).range(of: "Done").location
        textView.selectedRange = NSRange(location: doneLocation, length: 0)
        XCTAssertTrue(focusedText(in: textView).contains("\"Done!\""))
    }

    func testSentenceSelectionExpandsContinuouslyAcrossTouchedSentences() {
        let text = "First. Second! Third?"
        let textView = makeFocusedTextView(text: text)
        textView.focusGranularity = .sentence
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 2, length: 10)

        XCTAssertEqual(textView.focusedRanges.count, 1)
        XCTAssertTrue(focusedText(in: textView).hasPrefix("First. Second!"))
    }

    func testSentenceFocusKeepsURLsEmailsAndEllipsesTogether() {
        let text = "Visit example.com now. Email a@b.com... Done? Next."
        let textView = makeFocusedTextView(text: text)
        textView.focusGranularity = .sentence
        textView.isFocusModeEnabled = true

        let urlLocation = (text as NSString).range(of: "example.com").location
        textView.selectedRange = NSRange(location: urlLocation, length: 0)
        XCTAssertTrue(focusedText(in: textView).contains("example.com"))

        let emailLocation = (text as NSString).range(of: "a@b.com").location
        textView.selectedRange = NSRange(location: emailLocation, length: 0)
        XCTAssertTrue(focusedText(in: textView).contains("a@b.com..."))
    }

    func testTextEditInvalidatesFocusedSentence() {
        let textView = makeFocusedTextView(text: "One. Two.")
        textView.focusGranularity = .sentence
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 1, length: 0)

        textView.replace(NSRange(location: 0, length: 4), withText: "Changed!")
        textView.selectedRange = NSRange(location: 1, length: 0)

        XCTAssertTrue(focusedText(in: textView).hasPrefix("Changed!"))
    }

    func testMultipleCaretsKeepIndependentSentencesFocused() {
        let text = "First. Second. Third."
        let textView = makeFocusedTextView(text: text)
        textView.focusGranularity = .sentence
        textView.isFocusModeEnabled = true
        textView.selectedRanges = [
            NSRange(location: 1, length: 0),
            NSRange(location: 16, length: 0)
        ]

        XCTAssertEqual(textView.focusedRanges.count, 2)
    }

    func testEmptyDocumentAndBlankLineDoNotCrash() {
        let empty = makeFocusedTextView(text: "")
        empty.isFocusModeEnabled = true
        XCTAssertTrue(empty.focusedRanges.isEmpty)

        let blank = makeFocusedTextView(text: "One\n\nTwo")
        blank.isFocusModeEnabled = true
        blank.selectedRange = NSRange(location: 4, length: 0)
        XCTAssertTrue(blank.focusedRanges.isEmpty)
    }

    func testCachedCaretUpdatesStayBelowTwoMilliseconds() {
        let paragraph = Array(repeating: "Dr. Smith paid 3.14. Next sentence.", count: 40).joined(separator: " ")
        let textView = makeFocusedTextView(text: paragraph)
        textView.focusGranularity = .sentence
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 1, length: 0)

        let start = ContinuousClock.now
        for location in 1...100 {
            textView.selectedRange = NSRange(location: location, length: 0)
        }
        let elapsed = start.duration(to: .now)
        let components = elapsed.components
        let totalMilliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
        let averageMilliseconds = totalMilliseconds / 100
        XCTAssertLessThan(averageMilliseconds, 2)
    }

    private func focusedText(in textView: TextView) -> String {
        guard let range = textView.focusedRanges.first else { return "" }
        return (textView.text as NSString).substring(with: range)
    }

    /// Typing into a scaled Markdown heading must not change the line's metrics. The edit used to
    /// rebuild the whole line at the body size until the highlight landed, so the caret jumped left
    /// and the lines below it moved up on every keystroke, then both snapped back.
    func testTypingInHeadingKeepsCaretAndLineHeightStable() throws {
        let body = (0 ..< 6).map { "Paragraph \($0) has some words in it." }.joined(separator: "\n\n")
        let text = "# \n\n" + body
        let palette = ThemeCatalog.palette(id: ThemeCatalog.defaultLightID, fallbackDark: false)
        let textView = makeFocusedTextView(text: "")
        textView.setState(TextViewState(text: text,
                                        theme: PaletteTheme(palette: palette, postscriptName: nil),
                                        language: .markdown,
                                        languageProvider: MarkdownLanguageProvider(),
                                        parsePolicy: .eager))
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.3)
        textView.layoutIfNeeded()
        try XCTSkipUnless(textView.isSyntaxTreeReady, "markdown tree not ready")
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 2, length: 0)
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.1)

        for character in "Hello world" {
            textView.insertText(String(character))
            textView.layoutIfNeeded()
            let immediate = textView.caretRect(at: textView.selectedRange.location)
            pumpMainRunLoop(for: 0.15)
            textView.layoutIfNeeded()
            let settled = textView.caretRect(at: textView.selectedRange.location)
            XCTAssertEqual(immediate.minX, settled.minX, accuracy: 0.5, "caret x moved after typing '\(character)'")
            XCTAssertEqual(immediate.height, settled.height, accuracy: 0.5, "line height changed after typing '\(character)'")
        }
    }

    /// Deleting in a scaled Markdown heading must keep the caret where the text puts it, whether the
    /// deletion takes the last character of the title, joins the next line into it, or edits its `#`s.
    /// Each used to rebuild the line at the body size until the parse landed.
    func testBackspaceInHeadingKeepsCaretStable() throws {
        let doc = "# Title\n\nIntro paragraph.\n\n## First section heading\nTight paragraph below.\n\n## Last\n\nTail.\n"
        let cases: [(name: String, after: String, backspaces: Int)] = [
            ("end of title", "## First section heading", 6),
            ("join next line into title", "## First section heading\n", 1),
            ("delete a # of ##", "\n\n##", 1)
        ]
        let palette = ThemeCatalog.palette(id: ThemeCatalog.defaultLightID, fallbackDark: false)
        for testCase in cases {
            let textView = makeFocusedTextView(text: "")
            textView.setState(TextViewState(text: doc,
                                            theme: PaletteTheme(palette: palette, postscriptName: nil),
                                            language: .markdown,
                                            languageProvider: MarkdownLanguageProvider(),
                                            parsePolicy: .eager))
            textView.layoutIfNeeded()
            pumpMainRunLoop(for: 0.3)
            textView.layoutIfNeeded()
            try XCTSkipUnless(textView.isSyntaxTreeReady, "markdown tree not ready")
            textView.isFocusModeEnabled = true
            let anchor = (doc as NSString).range(of: testCase.after, options: .backwards)
            textView.selectedRange = NSRange(location: anchor.upperBound, length: 0)
            textView.layoutIfNeeded()
            pumpMainRunLoop(for: 0.1)

            for step in 1 ... testCase.backspaces {
                textView.deleteBackward()
                textView.layoutIfNeeded()
                let immediate = textView.caretRect(at: textView.selectedRange.location)
                pumpMainRunLoop(for: 0.15)
                textView.layoutIfNeeded()
                let settled = textView.caretRect(at: textView.selectedRange.location)
                XCTAssertEqual(immediate.minX, settled.minX, accuracy: 0.5, "\(testCase.name): caret x moved after backspace \(step)")
                XCTAssertEqual(immediate.height, settled.height, accuracy: 0.5, "\(testCase.name): line height changed after backspace \(step)")
            }
        }
    }

    /// The caret moves before the text changes, so Focus Mode used to resolve its ranges against the
    /// old text and the edited line was painted dimmed for one frame on every keystroke. The very
    /// first layout after an edit must already paint the edited paragraph at full opacity.
    func testEditedParagraphIsNeverPaintedDimmed() throws {
        try XCTSkipUnless(MetalContext.isAvailable, "Metal is not available")
        let doc = "# Title\n\nAlpha paragraph has some words in it and goes on a while.\n\nBravo paragraph is the second one.\n"
        let textView = makeFocusedTextView(text: "")
        textView.isMetalRenderingEnabled = true
        textView.setState(TextViewState(text: doc,
                                        theme: DefaultTheme(),
                                        language: .markdown,
                                        languageProvider: MarkdownLanguageProvider(),
                                        parsePolicy: .eager))
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.3)
        textView.layoutIfNeeded()
        try XCTSkipUnless(textView.isMetalRenderingActive, "Metal rendering did not activate")
        textView.isFocusModeEnabled = true
        let end = (doc as NSString).range(of: "a while.").upperBound
        textView.selectedRange = NSRange(location: end, length: 0)
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.1)

        func alphas(of word: String) -> [Float] {
            let location = (textView.text as NSString).range(of: word).location
            return textView.metalDebugGlyphColors(atLocation: location + 1).map(\.w)
        }
        let unfocusedAlpha = Float(textView.unfocusedTextAlpha)
        let edits: [(String, () -> Void)] = [
            ("type at end", { textView.insertText(" Hello") }),
            ("type in middle", {
                let middle = (textView.text as NSString).range(of: "some").upperBound
                textView.selectedRange = NSRange(location: middle, length: 0)
                textView.insertText("x")
            }),
            ("backspace", { textView.deleteBackward() })
        ]
        for (name, edit) in edits {
            edit()
            textView.layoutIfNeeded()
            let edited = alphas(of: "Alpha")
            XCTAssertFalse(edited.isEmpty, "\(name): the edited paragraph should be painted")
            XCTAssertEqual(edited.min() ?? 0, 1, accuracy: 0.01, "\(name): the edited paragraph was painted dimmed")
            let other = alphas(of: "Bravo")
            XCTAssertEqual(other.max() ?? 0, unfocusedAlpha, accuracy: 0.01, "\(name): the other paragraph lost its dimming")
        }
    }

    /// Typing re-highlights the lines the parse changed (a heading, a blockquote). While that is
    /// pending, Metal carries the glyphs' previous colors over; those must be the undimmed ones. The
    /// dimmed ones were dimmed a second time (alpha squared), so those lines pulsed darker and back
    /// on every keystroke.
    func testPendingHighlightDoesNotDimUnfocusedLinesTwice() throws {
        try XCTSkipUnless(MetalContext.isAvailable, "Metal is not available")
        let doc = """
        # 🂡 Balatro4j

        > A high-performance seed analyzer, based on [Immolate](https://github.com/example/immolate).

        [![Release](https://example.com/badge.svg)](https://example.com/actions)

        ---

        ## ✨ Feature

        - **🔍 Seed Finder** — Fully customizable multi-threaded seed search API
        - **⚡ Vector Finder** — SIMD-accelerated search (`jdk.incubator.vector`)

        ---

        ## 📸 Demo

        <!-- TODO: Add screenshot here -->
        """
        let palette = ThemeCatalog.palette(id: ThemeCatalog.defaultDarkID, fallbackDark: true)
        let textView = makeFocusedTextView(text: "")
        textView.isMetalRenderingEnabled = true
        textView.setState(TextViewState(text: doc,
                                        theme: PaletteTheme(palette: palette, postscriptName: nil),
                                        language: .markdown,
                                        languageProvider: MarkdownLanguageProvider(),
                                        parsePolicy: .eager))
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.5)
        textView.layoutIfNeeded()
        try XCTSkipUnless(textView.isMetalRenderingActive, "Metal rendering did not activate")
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: (doc as NSString).range(of: "## ✨ Feature").upperBound, length: 0)
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.3)

        let unfocusedAlpha = Float(textView.unfocusedTextAlpha)
        var minimumAlpha = Float.greatestFiniteMagnitude
        for step in 0 ..< 4 {
            if step.isMultiple(of: 2) { textView.insertText("s") } else { textView.deleteBackward() }
            for _ in 0 ..< 40 {
                textView.layoutIfNeeded()
                for word in ["Balatro4j", "A high-performance", "Seed Finder"] {
                    let location = (textView.text as NSString).range(of: word).location
                    for color in textView.metalDebugGlyphColors(atLocation: location + 1) {
                        minimumAlpha = min(minimumAlpha, color.w)
                    }
                }
                pumpMainRunLoop(for: 0.004)
            }
        }
        XCTAssertLessThan(minimumAlpha, Float.greatestFiniteMagnitude, "the unfocused lines should be painted")
        XCTAssertGreaterThanOrEqual(minimumAlpha, unfocusedAlpha - 0.01,
                                    "an unfocused line was dimmed below the unfocused alpha while its highlight was pending")
    }
}
