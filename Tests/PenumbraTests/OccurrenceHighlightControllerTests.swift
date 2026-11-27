import XCTest
@testable import Penumbra

@MainActor
final class OccurrenceHighlightControllerTests: XCTestCase {
    private func makeController(
        text: String,
        configuration: LanguageConfiguration = .javaScript,
        enabled: Bool = true
    ) -> (OccurrenceHighlightController, EmphasisManager) {
        let stringView = StringView(string: text)
        let controller = OccurrenceHighlightController(stringView: stringView, theme: DefaultTheme())
        controller.debounceInterval = 0
        let emphasisManager = EmphasisManager()
        controller.emphasisManager = emphasisManager
        controller.configuration = configuration
        controller.isEnabled = enabled
        return (controller, emphasisManager)
    }

    /// Runs the (zero-delay) debounced work item.
    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func occurrences(_ manager: EmphasisManager) -> [Emphasis] {
        manager.getEmphases(for: EmphasisGroup.occurrences)
    }

    func testExplicitSelectionHighlightsEveryMatch() {
        let text = "let total = total + total;"
        let (controller, manager) = makeController(text: text)
        let firstTotal = (text as NSString).range(of: "total")
        controller.selectionDidChange(selectedRange: firstTotal, isMultiCaret: false)
        pump()
        XCTAssertEqual(occurrences(manager).count, 3)
    }

    func testCurrentOccurrenceIsActiveOthersInactive() {
        let text = "foo foo foo"
        let (controller, manager) = makeController(text: text)
        let second = (text as NSString).range(of: "foo", options: [], range: NSRange(location: 4, length: 7))
        controller.selectionDidChange(selectedRange: second, isMultiCaret: false)
        pump()
        let emphases = occurrences(manager)
        XCTAssertEqual(emphases.count, 3)
        XCTAssertEqual(emphases.filter { !$0.inactive }.map(\.range), [second])
        XCTAssertEqual(emphases.filter { $0.inactive }.count, 2)
    }

    func testBelowMinimumLengthDoesNothing() {
        var config = LanguageConfiguration.javaScript
        config.minimumOccurrenceLength = 3
        let text = "ab ab ab"
        let (controller, manager) = makeController(text: text, configuration: config)
        controller.selectionDidChange(selectedRange: (text as NSString).range(of: "ab"), isMultiCaret: false)
        pump()
        XCTAssertTrue(occurrences(manager).isEmpty)
    }

    func testSelectionSpanningNewlineBails() {
        let text = "name\nname\nname"
        let (controller, manager) = makeController(text: text)
        controller.selectionDidChange(selectedRange: NSRange(location: 0, length: 6), isMultiCaret: false)
        pump()
        XCTAssertTrue(occurrences(manager).isEmpty)
    }

    func testWhitespaceOnlySelectionBails() {
        let text = "a    a    a"
        let (controller, manager) = makeController(text: text)
        controller.selectionDidChange(selectedRange: NSRange(location: 1, length: 4), isMultiCaret: false)
        pump()
        XCTAssertTrue(occurrences(manager).isEmpty)
    }

    func testMultiCaretBails() {
        let text = "x1 x1 x1"
        let (controller, manager) = makeController(text: text)
        controller.selectionDidChange(selectedRange: (text as NSString).range(of: "x1"), isMultiCaret: true)
        pump()
        XCTAssertTrue(occurrences(manager).isEmpty)
    }

    func testSingleOccurrenceIsNotHighlighted() {
        let text = "unique thing here"
        let (controller, manager) = makeController(text: text)
        controller.selectionDidChange(selectedRange: (text as NSString).range(of: "unique"), isMultiCaret: false)
        pump()
        XCTAssertTrue(occurrences(manager).isEmpty)
    }

    func testMatchCountIsCapped() {
        let word = "dup"
        let text = Array(repeating: word, count: OccurrenceHighlightController.maxMatches + 50).joined(separator: " ")
        let (controller, manager) = makeController(text: text)
        controller.selectionDidChange(selectedRange: NSRange(location: 0, length: word.count), isMultiCaret: false)
        pump()
        XCTAssertLessThanOrEqual(occurrences(manager).count, OccurrenceHighlightController.maxMatches)
        XCTAssertGreaterThan(occurrences(manager).count, 1)
    }

    func testDisablingClearsEmphases() {
        let text = "foo foo foo"
        let (controller, manager) = makeController(text: text)
        controller.selectionDidChange(selectedRange: (text as NSString).range(of: "foo"), isMultiCaret: false)
        pump()
        XCTAssertFalse(occurrences(manager).isEmpty)
        controller.isEnabled = false
        XCTAssertTrue(occurrences(manager).isEmpty)
    }

    func testConfigurationWithOccurrencesOffDoesNothing() {
        var config = LanguageConfiguration.javaScript
        config.highlightsOccurrences = false
        let text = "foo foo foo"
        let (controller, manager) = makeController(text: text, configuration: config)
        controller.selectionDidChange(selectedRange: (text as NSString).range(of: "foo"), isMultiCaret: false)
        pump()
        XCTAssertTrue(occurrences(manager).isEmpty)
    }

    func testWordUnderCaretHighlightedViaTextView() {
        let source = "const value = 1;\nconst other = value + value;\n"
        let textView = makeFocusedTextView(text: source)
        textView.languageConfigurationOverride = .javaScript
        textView.highlightsOccurrencesOfSelection = true
        // Caret inside the first "value".
        textView.selectedRange = NSRange(location: 8, length: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let emphases = textView.emphasisManager.getEmphases(for: EmphasisGroup.occurrences)
        XCTAssertEqual(emphases.count, 3)
    }

    func testDocumentDidChangeDropsStaleOccurrences() {
        let text = "foo foo foo"
        let (controller, manager) = makeController(text: text)
        controller.selectionDidChange(selectedRange: (text as NSString).range(of: "foo"), isMultiCaret: false)
        pump()
        XCTAssertEqual(occurrences(manager).count, 3)

        // Switching files points the controller at a new buffer while the caret is
        // restored to the same range. The old highlights must go; "not" occurs once.
        let next = "nothing repeats itself here"
        controller.stringView = StringView(string: next)
        controller.documentDidChange(selectedRange: NSRange(location: 0, length: 3), isMultiCaret: false)
        pump()
        XCTAssertTrue(occurrences(manager).isEmpty)
    }

    func testDocumentDidChangeCancelsPendingSearchFromPreviousDocument() {
        let text = "foo foo foo"
        let (controller, manager) = makeController(text: text)
        controller.selectionDidChange(selectedRange: (text as NSString).range(of: "foo"), isMultiCaret: false)
        // Switch before the debounce fires: the "foo" search must never land.
        let next = "bar bar bar"
        controller.stringView = StringView(string: next)
        controller.documentDidChange(selectedRange: NSRange(location: 0, length: 3), isMultiCaret: false)
        pump()
        let found = occurrences(manager)
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { (next as NSString).substring(with: $0.range) == "bar" })
    }

    /// Tabbing to another file restores the same caret, so no selection change fires.
    /// The switch itself must drop the old highlights synchronously — before the fix they
    /// lingered until the debounced recompute landed (seconds on large files).
    func testSwitchingDocumentsViaSetStateDropsStaleOccurrences() {
        let textView = makeFocusedTextView(text: "foo foo foo")
        textView.languageConfigurationOverride = .javaScript
        textView.highlightsOccurrencesOfSelection = true
        textView.selectedRange = (textView.text as NSString).range(of: "foo")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(textView.emphasisManager.getEmphases(for: EmphasisGroup.occurrences).count, 3)

        // New file, caret restored to the identical range: no selection change fires.
        // "aaa" occurs once, so a correct recompute leaves nothing highlighted.
        textView.setState(TextViewState(text: "aaa bbb ccc", theme: textView.theme))
        textView.selectedRange = NSRange(location: 0, length: 3)
        XCTAssertTrue(
            textView.emphasisManager.getEmphases(for: EmphasisGroup.occurrences).isEmpty,
            "switching files must clear the previous file's highlights synchronously"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(textView.emphasisManager.getEmphases(for: EmphasisGroup.occurrences).isEmpty)
    }

    func testReplacingTextDropsStaleOccurrences() {
        let textView = makeFocusedTextView(text: "foo foo foo")
        textView.languageConfigurationOverride = .javaScript
        textView.highlightsOccurrencesOfSelection = true
        textView.selectedRange = (textView.text as NSString).range(of: "foo")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(textView.emphasisManager.getEmphases(for: EmphasisGroup.occurrences).count, 3)

        textView.text = "aaa bbb ccc"
        textView.selectedRange = NSRange(location: 0, length: 3)
        XCTAssertTrue(
            textView.emphasisManager.getEmphases(for: EmphasisGroup.occurrences).isEmpty,
            "replacing the text must clear the previous highlights synchronously"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(textView.emphasisManager.getEmphases(for: EmphasisGroup.occurrences).isEmpty)
    }
}
