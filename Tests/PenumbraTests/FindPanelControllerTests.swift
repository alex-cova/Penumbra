import XCTest
import AppKit
@testable import Penumbra

/// Minimal `FindPanelTarget` backed by a plain `NSMutableString`, so `FindPanelController` can be
/// exercised without a live `TextView`/window.
@MainActor
private final class FakeFindTarget: FindPanelTarget {
    let findPanelTargetView: NSView = NSView()
    private(set) var text: NSMutableString
    var selection: NSRange?
    private(set) var scrolledRanges: [NSRange] = []
    private(set) var appliedBatches: [BatchReplaceSet] = []

    init(text: String) {
        self.text = NSMutableString(string: text)
    }

    var findSelection: NSRange? { selection }
    var findTextSource: any FindTextSource { StringFindTextSource(text as String) }

    func selectedTextForFind() -> String? {
        guard let selection, selection.length > 0, NSMaxRange(selection) <= text.length else {
            return nil
        }
        return text.substring(with: selection)
    }

    func setSelectedRange(_ range: NSRange) {
        selection = range
    }

    func scrollRangeToVisible(_ range: NSRange) {
        scrolledRanges.append(range)
    }

    func search(for query: SearchQuery) -> [SearchResult] {
        let options = FindSearchOptions(query)
        let ranges = (try? FindSession.findRanges(
            query: options.query,
            in: text as String,
            matchCase: options.matchCase,
            wholeWord: options.wholeWord,
            useRegex: options.useRegex
        )) ?? []
        return ranges.map {
            SearchResult(range: $0, startLocation: TextLocation(lineNumber: 0, column: 0), endLocation: TextLocation(lineNumber: 0, column: 0))
        }
    }

    func search(for query: SearchQuery, replacingMatchesWith replacementText: String) -> [SearchReplaceResult] {
        search(for: query).map {
            SearchReplaceResult(range: $0.range, startLocation: $0.startLocation, endLocation: $0.endLocation, replacementText: replacementText)
        }
    }

    func replace(_ range: NSRange, withText newText: String) {
        text.replaceCharacters(in: range, with: newText)
    }

    func replaceText(in batchReplaceSet: BatchReplaceSet) {
        appliedBatches.append(batchReplaceSet)
        for replacement in batchReplaceSet.replacements.sorted(by: { $0.range.location > $1.range.location }) {
            text.replaceCharacters(in: replacement.range, with: replacement.text)
        }
    }

    func findPanelWillShow(panelHeight: CGFloat) {}
    func findPanelWillHide(panelHeight: CGFloat) {}
}

/// These exercise `FindPanelController`'s post-audit wiring onto `FindSession`/
/// `FindSearchScheduler`/`FindSearchEngine` (PERFORMANCE_AUDIT.md Phase 2 #5 / migration step 2),
/// in place of the previous synchronous `target.search(for:)` path. The debounce/off-main-actor
/// scheduling is real (not stubbed), so these are async tests with short real sleeps rather than
/// synchronous assertions.
@MainActor
final class FindPanelControllerTests: XCTestCase {
    /// Longer than `FindSearchScheduler.debounceNanoseconds` (200ms).
    private func waitForDebounce() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    /// Shorter than the debounce window, but enough for an `immediate: true` search's
    /// `Task.detached` to complete.
    private func waitForImmediateSearch() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testShowWithInitialQuerySelectsFirstMatchImmediately() async {
        let target = FakeFindTarget(text: "alpha beta alpha")
        let controller = FindPanelController(target: target)
        controller.show(initialQuery: "alpha")
        await waitForImmediateSearch()

        XCTAssertEqual(target.selection, NSRange(location: 0, length: 5))
        XCTAssertEqual(controller.panelView.matchLabelText, "1/2")
    }

    func testTypingIsDebouncedBeforeUpdatingSelection() async {
        let target = FakeFindTarget(text: "needle hay needle")
        let controller = FindPanelController(target: target)
        controller.show()
        controller.panelView.onFindTextChanged?("needle")

        // Right after typing, the debounce window hasn't elapsed, so nothing has moved yet — the
        // whole point of wiring the debounced engine instead of the old synchronous search.
        XCTAssertNil(target.selection)

        await waitForDebounce()
        XCTAssertEqual(target.selection, NSRange(location: 0, length: 6))
        XCTAssertEqual(controller.panelView.matchLabelText, "1/2")
    }

    func testNextMatchWrapsWhenWrapAroundEnabled() async {
        let target = FakeFindTarget(text: "a b a")
        let controller = FindPanelController(target: target)
        controller.show(initialQuery: "a")
        await waitForImmediateSearch()
        XCTAssertEqual(target.selection, NSRange(location: 0, length: 1))

        controller.panelView.onNext?()
        XCTAssertEqual(target.selection, NSRange(location: 4, length: 1))

        controller.panelView.onNext?()
        XCTAssertEqual(target.selection, NSRange(location: 0, length: 1), "should wrap back to the first match")
    }

    func testNextMatchDoesNotWrapWhenWrapAroundDisabled() async {
        let target = FakeFindTarget(text: "a b a")
        let controller = FindPanelController(target: target)
        controller.panelView.onWrapAroundChanged?(false)
        controller.show(initialQuery: "a")
        await waitForImmediateSearch()
        XCTAssertEqual(target.selection, NSRange(location: 0, length: 1))

        controller.panelView.onNext?()
        XCTAssertEqual(target.selection, NSRange(location: 4, length: 1))

        controller.panelView.onNext?()
        XCTAssertEqual(target.selection, NSRange(location: 4, length: 1), "should stay on the last match, not wrap")
    }

    func testReplaceCurrentReplacesTheSelectedMatch() async {
        let target = FakeFindTarget(text: "foo bar foo")
        let controller = FindPanelController(target: target)
        controller.show(initialQuery: "foo")
        await waitForImmediateSearch()
        controller.panelView.replaceField.stringValue = "BAZ"

        controller.panelView.onReplace?()
        XCTAssertEqual(target.text as String, "BAZ bar foo")
    }

    func testReplaceAllReplacesEveryMatch() async {
        let target = FakeFindTarget(text: "foo bar foo")
        let controller = FindPanelController(target: target)
        controller.show(initialQuery: "foo")
        await waitForImmediateSearch()
        controller.panelView.replaceField.stringValue = "BAZ"

        controller.panelView.onReplaceAll?()
        XCTAssertEqual(target.text as String, "BAZ bar BAZ")
    }

    func testReplaceAllExpandsRegexCaptureGroups() async {
        let target = FakeFindTarget(text: "user@host other@box")
        let controller = FindPanelController(target: target)
        controller.panelView.onUsesRegularExpressionChanged?(true)
        controller.show(initialQuery: #"(\w+)@(\w+)"#)
        await waitForImmediateSearch()
        controller.panelView.replaceField.stringValue = "$2:$1"

        controller.panelView.onReplaceAll?()
        XCTAssertEqual(target.text as String, "host:user box:other")
    }

    func testHidingCancelsInFlightSearch() async {
        let target = FakeFindTarget(text: "needle hay needle")
        let controller = FindPanelController(target: target)
        controller.show()
        controller.panelView.onFindTextChanged?("needle")
        controller.hide()

        await waitForDebounce()
        XCTAssertNil(target.selection, "a search that was in flight when the panel closed shouldn't apply its result afterwards")
    }

    func testOpenPanelAndReplaceAllOnFileBackedBufferDoesNotMaterialize() async throws {
        let original = "foo bar foo"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try original.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        let state = try await TextViewState.load(contentsOf: url)
        XCTAssertTrue(state.stringView.isFileBacked)
        XCTAssertEqual(state.stringView.materializeCount, 0)

        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(state)
        let controller = FindPanelController(target: textView)
        controller.show(initialQuery: "foo")
        await waitForImmediateSearch()
        XCTAssertEqual(state.stringView.materializeCount, 0)

        controller.panelView.replaceField.stringValue = "BAZ"
        controller.panelView.onReplaceAll?()
        await waitForImmediateSearch()

        XCTAssertEqual(
            state.stringView.substring(in: NSRange(location: 0, length: state.stringView.length)),
            "BAZ bar BAZ"
        )
        XCTAssertEqual(state.stringView.materializeCount, 0)
    }
}
