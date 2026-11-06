import XCTest
import AppKit
@testable import Penumbra
import EditorIntelligence

/// The completion popup's own behaviour: it keeps its place across the refreshes that async
/// providers cause, tells VoiceOver what is on screen, and explains clipped rows.
@MainActor
final class CompletionPanelViewTests: XCTestCase {
    private let range = TextRange(
        start: TextPosition(line: 0, column: 0, utf16Offset: 0),
        end: TextPosition(line: 0, column: 0, utf16Offset: 0)
    )

    /// Fresh items on every call, as a provider's next batch would be (new `id`s, same content).
    private func items(_ names: [String], detail: String? = nil) -> [CompletionItem] {
        names.map {
            CompletionItem(label: $0, insertText: $0, kind: .function, range: range, source: "Test", detail: detail)
        }
    }

    private func model(_ items: [CompletionItem], selected: Int?, showsKeyHint: Bool = true) -> CompletionPanelModel {
        CompletionPanelModel(items: items, selectedIndex: selected, replacementRange: range, showsKeyHint: showsKeyHint)
    }

    private func makePanel(_ model: CompletionPanelModel) -> CompletionPanelView {
        let panel = CompletionPanelView(model: model)
        panel.frame = NSRect(origin: .zero, size: CompletionPanelView.preferredSize(for: model))
        return panel
    }

    private let names = (0..<60).map { String(format: "item%02d", $0) }

    // MARK: Scroll anchor

    func testARefreshKeepsTheSelectedRowAtTheSameDistanceFromTheTop() {
        let panel = makePanel(model(items(names), selected: nil))
        panel.update(model: model(items(names), selected: 30))
        let before = 30 - panel.firstVisibleIndex
        XCTAssertTrue((0..<CompletionPanelView.maxVisibleRows).contains(before))

        // The next batch brings five new rows in front; the list a user is reading shifts down.
        let next = items((0..<5).map { "new\($0)" } + names)
        panel.update(model: model(next, selected: 35))
        XCTAssertEqual(35 - panel.firstVisibleIndex, before, "the selected row did not move on screen")
    }

    func testARefreshWithTheSameRowsDoesNotMoveTheList() {
        let panel = makePanel(model(items(names), selected: nil))
        panel.update(model: model(items(names), selected: 40))
        let first = panel.firstVisibleIndex
        panel.update(model: model(items(names), selected: 40))
        XCTAssertEqual(panel.firstVisibleIndex, first, "fresh ids alone are not a change")
        XCTAssertGreaterThan(first, 0)
    }

    func testTheListStartsOverWhenTheAnchoredRowIsGone() {
        let panel = makePanel(model(items(names), selected: nil))
        panel.update(model: model(items(names), selected: 40))
        panel.update(model: model(items(["other1", "other2", "other3"]), selected: 0))
        XCTAssertEqual(panel.firstVisibleIndex, 0)
    }

    func testWithNothingSelectedTheTopVisibleRowIsTheAnchor() {
        let panel = makePanel(model(items(names), selected: nil))
        panel.update(model: model(items(names), selected: 40))
        panel.update(model: model(items(names), selected: nil))
        let top = panel.firstVisibleIndex
        panel.update(model: model(items(["x"] + names), selected: nil))
        XCTAssertEqual(panel.firstVisibleIndex, top + 1, "the same row stays on top")
    }

    // MARK: Accessibility

    func testVoiceOverSeesOneRowPerVisibleItemWithItsLabel() throws {
        let list = [
            CompletionItem(label: "size", insertText: "size", kind: .method, range: range, source: "Test",
                           detail: "int", labelDetail: "()"),
            CompletionItem(label: "old", insertText: "old", kind: .method, range: range, source: "Test",
                           isDeprecated: true),
        ]
        let panel = makePanel(model(list, selected: 1))
        let rows = try XCTUnwrap(panel.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(rows.map { $0.accessibilityLabel() }, ["size(), int", "old, deprecated"])
        XCTAssertEqual(rows.map { $0.isAccessibilitySelected() }, [false, true])
        XCTAssertEqual(panel.accessibilityRole(), .list)
        XCTAssertEqual((panel.accessibilitySelectedChildren() as? [NSAccessibilityElement])?.count, 1)
    }

    func testOnlyTheRowsOnScreenAreAccessibilityChildren() throws {
        let panel = makePanel(model(items(names), selected: nil))
        panel.update(model: model(items(names), selected: 40))
        let rows = try XCTUnwrap(panel.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(rows.count, CompletionPanelView.maxVisibleRows)
        XCTAssertEqual(rows.first?.accessibilityLabel(), names[panel.firstVisibleIndex])
    }

    // MARK: Footer hint

    func testTheKeyHintAddsAFooterAndCanBeSwitchedOff() {
        let list = items(["a", "b"])
        let withHint = model(list, selected: 0)
        let without = model(list, selected: 0, showsKeyHint: false)
        XCTAssertTrue(withHint.showsFooter)
        XCTAssertFalse(without.showsFooter)
        XCTAssertEqual(
            CompletionPanelView.preferredSize(for: withHint).height - CompletionPanelView.preferredSize(for: without).height,
            CompletionPanelView.footerHeight
        )
        XCTAssertFalse(model([], selected: nil).showsFooter, "no rows, nothing to accept")
        XCTAssertTrue(CompletionPanelView.keyHint.contains("Insert") && CompletionPanelView.keyHint.contains("Replace"))
    }

    // MARK: Tooltips

    func testOnlyClippedRowsGetATooltipCandidate() {
        let long = String(repeating: "Collections.unmodifiableList", count: 6)
        let list = items(["short"], detail: "int") + items([long], detail: "java.util.List<String>")
        let panel = makePanel(model(list, selected: 0))
        panel.frame.size.width = CompletionPanelView.minimumWidth
        XCTAssertFalse(panel.isTruncated(list[0]))
        XCTAssertTrue(panel.isTruncated(list[1]))
    }
}
