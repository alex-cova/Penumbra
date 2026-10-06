import AppKit
import XCTest
import EditorIntelligence
@testable import Penumbra

@MainActor
final class OutlineSidebarSelectionTests: XCTestCase {
    private func item(_ title: String, offset: Int) -> OutlineItem {
        OutlineItem(
            title: title,
            kind: .function,
            range: TextRange(
                start: TextPosition(line: 0, column: offset, utf16Offset: offset),
                end: TextPosition(line: 0, column: offset + 3, utf16Offset: offset + 3)
            )
        )
    }

    func testReflectingTheCaretItemDoesNotReportAUserSelection() {
        let view = OutlineSidebarView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        var picked: [String] = []
        view.onSelectItem = { picked.append($0.title) }
        let get = item("GET", offset: 0)
        let other = item("POST", offset: 40)

        view.update(model: OutlineModel(items: [get, other], selectedItemID: get.id))
        view.update(model: OutlineModel(items: [get, other], selectedItemID: other.id))

        XCTAssertEqual(picked, [])
    }
}
