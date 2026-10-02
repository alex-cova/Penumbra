import AppKit
import XCTest
@testable import Penumbra

/// Lines the view has not laid out yet are sized by an estimate. If it ignores the line-height
/// multiplier, every line grows when it is first laid out, so the content height and the scroll
/// position shift while scrolling through an opened file.
@MainActor
final class TextViewLineHeightEstimateTests: XCTestCase {
    func testStateEstimatesLinesAtTheHeightTheyAreLaidOutWith() {
        let theme = DefaultTheme()
        let text = (0 ..< 200).map { "line \($0)" }.joined(separator: "\n")
        let state = TextViewState(text: text, theme: theme)

        let expected = theme.font.totalLineHeight * TextView.defaultLineHeightMultiplier
        XCTAssertEqual(state.lineManager.contentHeight, expected * CGFloat(state.lineManager.lineCount), accuracy: 1)
    }

    func testContentHeightBarelyChangesOnceLinesAreLaidOut() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = textView
        let text = (0 ..< 200).map { "line \($0)" }.joined(separator: "\n")
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.layoutIfNeeded()
        let estimated = textView.contentSize.height

        textView.contentOffset = CGPoint(x: 0, y: 1_000)
        textView.layoutIfNeeded()

        XCTAssertEqual(textView.contentSize.height, estimated, accuracy: 20)
    }

    /// A state is prepared at the default multiplier. A view set to another one must move the
    /// lines it has not laid out onto its own estimate, or they keep the default height until
    /// scrolled into view: the content height drifts and the minimap's rows are uneven.
    func testStatePreparedAtDefaultMultiplierAdoptsTheViewsMultiplier() {
        let (window, textView) = makeTextView()
        _ = window
        textView.lineHeightMultiplier = 1
        let text = (0 ..< 2_000).map { "line \($0)" }.joined(separator: "\n")
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        settle(textView)

        let lineManager = textView.lineManagerForTesting
        let expected = DefaultTheme().font.totalLineHeight
        XCTAssertEqual(lineManager.lineInfo(atRow: 1_999).lineHeight, expected, accuracy: 0.01)
        let initialHeight = lineManager.contentHeight
        XCTAssertEqual(initialHeight, expected * 2_000, accuracy: 20)

        textView.contentOffset = CGPoint(x: 0, y: initialHeight / 2)
        settle(textView)
        XCTAssertGreaterThan(textView.contentOffset.y, initialHeight / 4)
        XCTAssertEqual(lineManager.contentHeight, initialHeight, accuracy: 20)
    }

    /// A state built at the view's multiplier is already at the right height, so `setState` has
    /// no lines to resize. Covers the text path and the file-load (packed index) path.
    func testStateBuiltAtTheViewsMultiplierStartsAtThatHeight() async throws {
        let theme = DefaultTheme()
        let text = (0 ..< 200).map { "line \($0)" }.joined(separator: "\n")
        let expected = theme.font.totalLineHeight

        let fromText = TextViewState(text: text, theme: theme, lineHeightMultiplier: 1)
        XCTAssertEqual(fromText.lineManager.lineInfo(atRow: 199).lineHeight, expected, accuracy: 0.01)
        XCTAssertEqual(fromText.lineManager.contentHeight, expected * 200, accuracy: 1)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try await TextViewState.load(contentsOf: url, theme: theme, lineHeightMultiplier: 1)
        XCTAssertEqual(loaded.lineManager.lineInfo(atRow: 199).lineHeight, expected, accuracy: 0.01)
        XCTAssertEqual(loaded.lineManager.contentHeight, expected * 200, accuracy: 1)
    }

    func testChangingMultiplierMovesLinesNotYetLaidOut() {
        let (window, textView) = makeTextView()
        _ = window
        let text = (0 ..< 2_000).map { "line \($0)" }.joined(separator: "\n")
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        settle(textView)

        textView.lineHeightMultiplier = 1.5
        settle(textView)

        let expected = DefaultTheme().font.totalLineHeight * 1.5
        let lineManager = textView.lineManagerForTesting
        XCTAssertEqual(lineManager.lineInfo(atRow: 1_999).lineHeight, expected, accuracy: 0.01)
        XCTAssertEqual(lineManager.contentHeight, expected * 2_000, accuracy: 20)
        XCTAssertEqual(textView.contentSize.height, expected * 2_000, accuracy: 40)
    }

    /// The view applies its content size on the next run-loop turn, not during layout.
    private func settle(_ textView: TextView) {
        textView.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        textView.layoutIfNeeded()
    }

    private func makeTextView() -> (NSWindow, TextView) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = textView
        return (window, textView)
    }
}
