import AppKit
import XCTest
@testable import Penumbra

@MainActor
final class TextViewTypewriterScrollingTests: XCTestCase {
    private func multilineText(lineCount: Int) -> String {
        (1...lineCount).map { "Line \($0)" }.joined(separator: "\n")
    }

    private func location(ofLine number: Int, in text: String) -> Int {
        let lines = text.components(separatedBy: "\n")
        precondition(number >= 1 && number <= lines.count)
        return lines.prefix(number - 1).map { $0.count + 1 }.reduce(0, +)
    }

    private func viewportHeight(in textView: TextView) -> CGFloat {
        textView.frame.height
            - textView.adjustedContentInset.top
            - textView.adjustedContentInset.bottom
    }

    private func caretMidYRelativeToViewport(in textView: TextView, at location: Int) -> CGFloat? {
        guard let position = textView.position(from: textView.beginningOfDocument, offset: location) else {
            return nil
        }
        let caretRect = textView.caretRect(for: position)
        let viewportTop = textView.contentOffset.y + textView.adjustedContentInset.top
        return caretRect.midY - viewportTop
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
    }

    private func simulateUserScroll(deltaY: Int32, on textView: TextView) {
        let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        )!
        let event = NSEvent(cgEvent: cgEvent)!
        textView.scrollWheel(with: event)
    }

    func testTypewriterDisabledDoesNotRecenterVisibleCaret() {
        let text = multilineText(lineCount: 40)
        let textView = makeFocusedTextView(text: text)
        let line3 = location(ofLine: 3, in: text)

        textView.contentOffset = .zero
        textView.isTypewriterScrollingEnabled = false
        textView.isAutomaticScrollEnabled = true
        textView.scrollRangeToVisible(NSRange(location: line3, length: 0))
        textView.layoutIfNeeded()

        XCTAssertEqual(textView.contentOffset.y, 0, accuracy: 1)
    }

    func testTypewriterPinsLineAtCenter() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let line25 = location(ofLine: 25, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.typewriterAnchorFraction = 0.5
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: line25) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
    }

    func testTypewriterRespectsAnchorFraction() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let line25 = location(ofLine: 25, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.typewriterAnchorFraction = 0.25
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: line25) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.25, accuracy: 2)
    }

    func testTypewriterCentersFirstLineWithTopOverscroll() {
        let text = multilineText(lineCount: 40)
        let textView = makeFocusedTextView(text: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: 0) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
    }

    func testTypewriterClampsAtDocumentBottom() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let lastLine = location(ofLine: 60, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.scrollRangeToVisible(NSRange(location: lastLine, length: 0))
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: lastLine) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertGreaterThan(textView.contentOffset.y, 0)
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
    }

    func testEnablingTypewriterIncreasesContentSize() {
        let text = multilineText(lineCount: 10)
        let textView = makeFocusedTextView(text: text)

        textView.isTypewriterScrollingEnabled = false
        textView.layoutIfNeeded()
        drainMainQueue()
        let baseHeight = textView.contentSize.height

        textView.isTypewriterScrollingEnabled = true
        textView.layoutIfNeeded()
        drainMainQueue()

        let topExtra = TypewriterScrollingPolicy.requiredTopOverscroll(
            viewportHeight: textView.frame.height,
            anchorFraction: textView.typewriterAnchorFraction
        )
        let bottomExtra = TypewriterScrollingPolicy.requiredBottomOverscroll(
            viewportHeight: textView.frame.height,
            anchorFraction: textView.typewriterAnchorFraction
        )
        XCTAssertEqual(textView.contentSize.height - baseHeight, topExtra + bottomExtra, accuracy: 1)
    }

    func testScrollRangeToVisibleWithSelectionIgnoresTypewriter() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let start = location(ofLine: 20, in: text)
        let end = location(ofLine: 22, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.contentOffset = .zero
        textView.scrollRangeToVisible(NSRange(location: start, length: end - start))
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: start) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertNotEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
    }

    func testTypewriterRequiresAutomaticScrollEnabled() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let line25 = location(ofLine: 25, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = false
        textView.contentOffset = .zero
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        textView.layoutIfNeeded()

        XCTAssertEqual(textView.contentOffset.y, 0, accuracy: 1)
    }

    func testEnablingTypewriterMidDocumentReanchors() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let line25 = location(ofLine: 25, in: text)

        textView.selectedRange = NSRange(location: line25, length: 0)
        textView.contentOffset = .zero
        textView.isTypewriterScrollingEnabled = true
        drainMainQueue()
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: line25) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
    }

    func testChangingAnchorFractionReanchors() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let line25 = location(ofLine: 25, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.selectedRange = NSRange(location: line25, length: 0)
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        textView.layoutIfNeeded()

        textView.typewriterAnchorFraction = 0.25
        drainMainQueue()
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: line25) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.25, accuracy: 2)
    }

    func testFrameResizeReanchors() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let line25 = location(ofLine: 25, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.selectedRange = NSRange(location: line25, length: 0)
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        textView.layoutIfNeeded()

        textView.window?.setContentSize(NSSize(width: 400, height: 420))
        textView.layoutIfNeeded()
        drainMainQueue()
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: line25) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
    }

    func testReenablingAutomaticScrollReanchorsWithTypewriter() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let line25 = location(ofLine: 25, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = false
        textView.selectedRange = NSRange(location: line25, length: 0)
        textView.contentOffset = .zero
        textView.isAutomaticScrollEnabled = true
        drainMainQueue()
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: line25) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
    }

    func testTypewriterScrollsOnNewline() {
        let text = multilineText(lineCount: 40)
        let textView = makeFocusedTextView(text: text)
        let line15Start = location(ofLine: 15, in: text)
        let line16Start = location(ofLine: 16, in: text)
        let line15End = line16Start - 1

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.selectedRange = NSRange(location: line15End, length: 0)
        textView.scrollRangeToVisible(NSRange(location: line15End, length: 0))
        textView.layoutIfNeeded()

        let initialOffsetY = textView.contentOffset.y
        send(keyEvent(keyCode: TestKeyCode.returnKey, characters: "\r"), to: textView)
        drainMainQueue()
        textView.layoutIfNeeded()

        let newCaretLocation = line16Start
        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: newCaretLocation) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertGreaterThan(textView.contentOffset.y, initialOffsetY)
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
        XCTAssertNotEqual(newCaretLocation, line15Start)
    }

    func testDisablingTypewriterShrinksContentSize() {
        let text = multilineText(lineCount: 10)
        let textView = makeFocusedTextView(text: text)

        textView.isTypewriterScrollingEnabled = true
        textView.layoutIfNeeded()
        drainMainQueue()
        let withTypewriter = textView.contentSize.height

        textView.isTypewriterScrollingEnabled = false
        textView.layoutIfNeeded()
        drainMainQueue()

        XCTAssertLessThan(textView.contentSize.height, withTypewriter)
    }

    func testSingleLineDocumentAnchorsWithoutCrashing() {
        let textView = makeFocusedTextView(text: "Hello, world.")

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: 0) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
        XCTAssertGreaterThan(textView.contentSize.height, textView.frame.height * 0.5)
    }

    func testBlankLineAnchorsInMiddleOfDocument() {
        var lines = (1...30).map { "Line \($0)" }
        lines.insert("", at: 14)
        let text = lines.joined(separator: "\n")
        let textView = makeFocusedTextView(text: text)
        let blankLine = location(ofLine: 15, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.selectedRange = NSRange(location: blankLine, length: 0)
        textView.scrollRangeToVisible(NSRange(location: blankLine, length: 0))
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: blankLine) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
    }

    func testWrappedVisualLineContainingCaretIsAnchored() {
        let longLine = Array(repeating: "wrapped", count: 80).joined(separator: " ")
        let text = (1...20).map { $0 == 10 ? longLine : "Line \($0)" }.joined(separator: "\n")
        let textView = makeFocusedTextView(text: text)
        textView.frame.size.width = 180
        textView.layoutIfNeeded()
        let wrappedLineStart = location(ofLine: 10, in: text)
        let caret = wrappedLineStart + (longLine as NSString).length - 2

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.selectedRange = NSRange(location: caret, length: 0)
        textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: caret) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 3)
    }

    func testDisablingTypewriterRestoresStandardScrollBehavior() {
        let text = multilineText(lineCount: 40)
        let textView = makeFocusedTextView(text: text)
        let line3 = location(ofLine: 3, in: text)
        let line25 = location(ofLine: 25, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.selectedRange = NSRange(location: line25, length: 0)
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        textView.layoutIfNeeded()
        XCTAssertGreaterThan(textView.contentOffset.y, 0)

        textView.isTypewriterScrollingEnabled = false
        textView.contentOffset = .zero
        textView.selectedRange = NSRange(location: line3, length: 0)
        textView.scrollRangeToVisible(NSRange(location: line3, length: 0))
        textView.layoutIfNeeded()

        XCTAssertEqual(textView.contentOffset.y, 0, accuracy: 1)
    }

    func testUserScrollWheelSuspendsTypewriterUntilKeyPress() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let line25 = location(ofLine: 25, in: text)
        let line26 = location(ofLine: 26, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.selectedRange = NSRange(location: line25, length: 0)
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        textView.layoutIfNeeded()
        let anchoredOffsetY = textView.contentOffset.y

        simulateUserScroll(deltaY: 3, on: textView)
        XCTAssertNotEqual(textView.contentOffset.y, anchoredOffsetY, accuracy: 1)

        textView.selectedRange = NSRange(location: line26, length: 0)
        drainMainQueue()
        textView.layoutIfNeeded()
        guard let relativeMidYWhileSuspended = caretMidYRelativeToViewport(in: textView, at: line26) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertNotEqual(relativeMidYWhileSuspended, viewportHeight(in: textView) * 0.5, accuracy: 2)

        send(keyEvent(keyCode: TestKeyCode.downArrow), to: textView)
        drainMainQueue()
        drainMainQueue()
        textView.layoutIfNeeded()

        let line27 = location(ofLine: 27, in: text)
        XCTAssertEqual(textView.selectedRange.location, line27)
        guard let relativeMidYAfterKey = caretMidYRelativeToViewport(in: textView, at: line27) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidYAfterKey, viewportHeight(in: textView) * 0.5, accuracy: 4)
    }

    func testCaretRepositioningResumesTypewriterAfterManualScroll() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let line25 = location(ofLine: 25, in: text)
        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.selectedRange = NSRange(location: line25, length: 0)
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        textView.layoutIfNeeded()
        simulateUserScroll(deltaY: 3, on: textView)

        textView.resumeTypewriterScrollingAfterCaretRepositioning()
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        textView.layoutIfNeeded()

        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: line25) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 4)
    }

    func testDisablingTypewriterClearsUserSuspension() {
        let text = multilineText(lineCount: 60)
        let textView = makeFocusedTextView(text: text)
        let line25 = location(ofLine: 25, in: text)

        textView.isTypewriterScrollingEnabled = true
        textView.isAutomaticScrollEnabled = true
        textView.selectedRange = NSRange(location: line25, length: 0)
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        textView.layoutIfNeeded()

        simulateUserScroll(deltaY: 3, on: textView)
        let scrolledOffsetY = textView.contentOffset.y

        textView.isTypewriterScrollingEnabled = false
        textView.isTypewriterScrollingEnabled = true
        textView.selectedRange = NSRange(location: line25, length: 0)
        textView.scrollRangeToVisible(NSRange(location: line25, length: 0))
        drainMainQueue()
        textView.layoutIfNeeded()

        XCTAssertNotEqual(textView.contentOffset.y, scrolledOffsetY, accuracy: 1)
        guard let relativeMidY = caretMidYRelativeToViewport(in: textView, at: line25) else {
            return XCTFail("Missing caret position")
        }
        XCTAssertEqual(relativeMidY, viewportHeight(in: textView) * 0.5, accuracy: 2)
    }
}
