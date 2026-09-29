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
}
