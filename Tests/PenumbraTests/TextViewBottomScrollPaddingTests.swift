import AppKit
import XCTest
@testable import Penumbra

@MainActor
final class TextViewBottomScrollPaddingTests: XCTestCase {
    func testDefaultPaddingIsOneHundredPoints() {
        XCTAssertEqual(TextView(frame: .zero).bottomScrollPadding, 100)
    }

    func testPaddingExtendsContentHeight() {
        let (window, textView) = makeTextView()
        _ = window

        textView.bottomScrollPadding = 0
        settle(textView)
        let baseHeight = textView.contentSize.height

        textView.bottomScrollPadding = 100
        settle(textView)
        XCTAssertEqual(textView.contentSize.height - baseHeight, 100, accuracy: 1)

        textView.bottomScrollPadding = 0
        settle(textView)
        XCTAssertEqual(textView.contentSize.height, baseHeight, accuracy: 1)
    }

    func testNegativePaddingIsIgnored() {
        let (window, textView) = makeTextView()
        _ = window

        textView.bottomScrollPadding = 0
        settle(textView)
        let baseHeight = textView.contentSize.height

        textView.bottomScrollPadding = -50
        settle(textView)
        XCTAssertEqual(textView.contentSize.height, baseHeight, accuracy: 1)
    }

    func testPaddingIsNotAddedToVerticalOverscroll() {
        let (window, textView) = makeTextView()
        _ = window

        textView.bottomScrollPadding = 0
        textView.verticalOverscrollFactor = 1
        settle(textView)
        let withOverscroll = textView.contentSize.height

        textView.bottomScrollPadding = 100
        settle(textView)
        XCTAssertEqual(textView.contentSize.height, withOverscroll, accuracy: 1)
    }

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
        let text = (0 ..< 200).map { "line \($0)" }.joined(separator: "\n")
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        settle(textView)
        return (window, textView)
    }
}
