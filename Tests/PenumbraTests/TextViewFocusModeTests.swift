import XCTest
@testable import Penumbra

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

    func testParagraphFocusUsesSingleHardLine() {
        let text = "First line\nSecond line\nThird line"
        let textView = makeFocusedTextView(text: text)
        textView.focusGranularity = .paragraph
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 12, length: 0)

        XCTAssertEqual(textView.focusedRanges, [NSRange(location: 11, length: 11)])
    }

    func testParagraphFocusTreatsCRLFAsOneDelimiter() {
        let textView = makeFocusedTextView(text: "One\r\nTwo")
        textView.focusGranularity = .paragraph
        textView.isFocusModeEnabled = true
        textView.selectedRange = NSRange(location: 5, length: 0)

        XCTAssertEqual(textView.focusedRanges, [NSRange(location: 5, length: 3)])
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
}
