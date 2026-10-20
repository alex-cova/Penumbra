@preconcurrency import AppKit
import PenumbraMarkdownLanguage
import XCTest
@testable import Penumbra

/// Runs an edit in a Markdown document with scaled headings and checks that nothing moves or
/// changes once the parse that follows lands. While a parse is pending the edited lines are drawn
/// from a guess; any difference between that frame and the settled one is a visible jump.
extension XCTestCase {
    /// A laid-out Markdown view with a parsed tree, a palette theme that scales headings, and
    /// optionally Focus Mode and Metal. Skips the test when the tree or Metal is not available.
    @MainActor
    func makeMarkdownProbeView(document: String,
                               dark: Bool = false,
                               metal: Bool = false,
                               focusMode: Bool = false,
                               caretAfter anchor: String? = nil,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> TextView {
        if metal {
            try XCTSkipUnless(MetalContext.isAvailable, "Metal is not available")
        }
        let palette = dark
            ? ThemeCatalog.palette(id: ThemeCatalog.defaultDarkID, fallbackDark: true)
            : ThemeCatalog.palette(id: ThemeCatalog.defaultLightID, fallbackDark: false)
        let textView = makeFocusedTextView(text: "", file: file, line: line)
        textView.window?.setContentSize(NSSize(width: 640, height: 700))
        textView.frame = CGRect(x: 0, y: 0, width: 640, height: 700)
        textView.isMetalRenderingEnabled = metal
        textView.setState(TextViewState(text: document,
                                        theme: PaletteTheme(palette: palette, postscriptName: nil),
                                        language: .markdown,
                                        languageProvider: MarkdownLanguageProvider(),
                                        parsePolicy: .eager))
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.3)
        textView.layoutIfNeeded()
        try XCTSkipUnless(textView.isSyntaxTreeReady, "markdown tree not ready")
        if metal {
            try XCTSkipUnless(textView.isMetalRenderingActive, "Metal rendering did not activate")
        }
        textView.isFocusModeEnabled = focusMode
        if let anchor {
            let range = (document as NSString).range(of: anchor)
            XCTAssertNotEqual(range.location, NSNotFound, "anchor '\(anchor)' not in the document", file: file, line: line)
            textView.selectedRange = NSRange(location: range.upperBound, length: 0)
        }
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.1)
        return textView
    }

    /// Pumps the run loop until the syntax tree is ready again and the highlight it triggers has had
    /// time to land. Returns false on timeout.
    @MainActor
    @discardableResult
    func waitForParse(in textView: TextView, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !textView.isSyntaxTreeReady {
            guard Date() < deadline else {
                return false
            }
            pumpMainRunLoop(for: 0.01)
        }
        pumpMainRunLoop(for: 0.2)
        textView.layoutIfNeeded()
        return true
    }

    /// Runs `action`, then samples the view after the first layout and every few milliseconds until
    /// the parse settles. Fails for any sample that differs from the settled one in:
    /// - the caret's x, y and height,
    /// - the y of each line that contains one of `watching` (found after the action),
    /// - with Focus Mode and Metal on and `focused` / `unfocused` given: the alpha of the glyphs of
    ///   the edited paragraph (full) and of an unfocused one (the unfocused alpha).
    @MainActor
    func assertEditIsStable(_ name: String,
                            in textView: TextView,
                            watching: [String] = [],
                            focused: String? = nil,
                            unfocused: String? = nil,
                            file: StaticString = #filePath,
                            line: UInt = #line,
                            action: () -> Void) {
        func sample() -> EditSample {
            textView.layoutIfNeeded()
            let text = textView.text as NSString
            let ys: [CGFloat?] = watching.map { snippet in
                let range = text.range(of: snippet)
                return range.location == NSNotFound ? nil : textView.caretRect(at: range.location).minY
            }
            func alphas(_ word: String?) -> [Float]? {
                guard let word, textView.isMetalRenderingActive else {
                    return nil
                }
                let range = text.range(of: word)
                guard range.location != NSNotFound else {
                    return nil
                }
                return textView.metalDebugGlyphColors(atLocation: range.location + 1).map(\.w)
            }
            return EditSample(caret: textView.caretRect(at: textView.selectedRange.location),
                              watchedYs: ys,
                              focusedAlphas: alphas(focused),
                              unfocusedAlphas: alphas(unfocused))
        }

        let textBefore = textView.text
        action()
        // An action that reaches nothing leaves every sample equal and the case vacuously green.
        XCTAssertNotEqual(textView.text, textBefore, "\(name): the action did not change the text", file: file, line: line)
        var samples = [sample()]
        let deadline = Date().addingTimeInterval(5)
        while !textView.isSyntaxTreeReady, Date() < deadline {
            pumpMainRunLoop(for: 0.005)
            samples.append(sample())
        }
        for _ in 0 ..< 40 {
            pumpMainRunLoop(for: 0.005)
            samples.append(sample())
        }
        pumpMainRunLoop(for: 0.1)
        let settled = sample()

        let focusDimming = textView.isFocusModeEnabled
        let unfocusedAlpha = Float(textView.unfocusedTextAlpha)
        for (index, current) in samples.enumerated() {
            let label = "\(name) (sample \(index))"
            XCTAssertEqual(current.caret.minX, settled.caret.minX, accuracy: 0.5, "\(label): caret x", file: file, line: line)
            XCTAssertEqual(current.caret.minY, settled.caret.minY, accuracy: 0.5, "\(label): caret y", file: file, line: line)
            XCTAssertEqual(current.caret.height, settled.caret.height, accuracy: 0.5, "\(label): caret height", file: file, line: line)
            for (snippetIndex, y) in current.watchedYs.enumerated() {
                guard let y, let settledY = settled.watchedYs[snippetIndex] else {
                    XCTAssertEqual(y == nil, settled.watchedYs[snippetIndex] == nil,
                                   "\(label): '\(watching[snippetIndex])' came or went", file: file, line: line)
                    continue
                }
                XCTAssertEqual(y, settledY, accuracy: 0.5, "\(label): y of '\(watching[snippetIndex])'", file: file, line: line)
            }
            guard focusDimming else {
                continue
            }
            if let alphas = current.focusedAlphas {
                XCTAssertEqual(alphas.min() ?? 1, 1, accuracy: 0.01, "\(label): the edited paragraph was painted dimmed", file: file, line: line)
            }
            if let alphas = current.unfocusedAlphas {
                XCTAssertEqual(alphas.max() ?? unfocusedAlpha, unfocusedAlpha, accuracy: 0.01,
                               "\(label): the unfocused paragraph is not at the unfocused alpha", file: file, line: line)
            }
        }
    }

    /// Selects the first occurrence of `text` and returns its range.
    @MainActor
    @discardableResult
    func select(_ text: String, in textView: TextView, file: StaticString = #filePath, line: UInt = #line) -> NSRange {
        let range = (textView.text as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "'\(text)' not in the document", file: file, line: line)
        textView.selectedRange = range
        return range
    }

    /// Puts the caret right after the first occurrence of `text`.
    @MainActor
    func placeCaret(after text: String, in textView: TextView, file: StaticString = #filePath, line: UInt = #line) {
        let range = select(text, in: textView, file: file, line: line)
        textView.selectedRange = NSRange(location: range.upperBound, length: 0)
    }

    /// Forward delete, sent as the key the editor handles (there is no selector for a test to call).
    @MainActor
    func pressForwardDelete(in textView: TextView) {
        send(keyEvent(keyCode: TestKeyCode.forwardDelete), to: textView)
    }

    /// Cut, through the first responder like the Edit menu. The pasteboard is restored afterwards.
    @MainActor
    func performCut(in textView: TextView, file: StaticString = #filePath, line: UInt = #line) {
        let saved = EditorPasteboard.general.string
        defer { EditorPasteboard.general.string = saved }
        let handled = textView.window?.firstResponder?.tryToPerform(#selector(NSText.cut(_:)), with: nil) ?? false
        XCTAssertTrue(handled, "the first responder did not handle cut", file: file, line: line)
    }
}

private struct EditSample {
    let caret: CGRect
    let watchedYs: [CGFloat?]
    let focusedAlphas: [Float]?
    let unfocusedAlphas: [Float]?
}

/// A README-style document: titles at two levels, a tight paragraph straight under a title, a
/// list, and paragraphs to focus and dim.
enum EditStabilityDocuments {
    static let readme = """
    # Title

    Intro paragraph has some words in it and goes on a while.

    ## First section heading
    Tight paragraph directly below the heading.

    - First list item
    - Second list item

    ## Second section heading

    Final paragraph is the unfocused one.
    """
}
