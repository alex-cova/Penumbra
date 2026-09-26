@preconcurrency import AppKit
import EditorIntelligence
@testable import Penumbra
import XCTest

@MainActor
final class NavigationChoicesViewTests: XCTestCase {
    func testModelLabelsEachLocationWithItsFolderAndFile() {
        let locations = [
            location("Circle", url: URL(fileURLWithPath: "/p/shapes/Circle.java")),
            location("Square", url: nil)
        ]
        let model = NavigationChoicesModel(identifier: "Shape", locations: locations)
        XCTAssertEqual(model.header, "Choose target for Shape (2)")
        XCTAssertEqual(model.rows, [
            .init(title: "Circle", subtitle: "shapes/Circle.java"),
            .init(title: "Square", subtitle: nil)
        ])
    }

    func testMoveSelectionWrapsAround() {
        let view = NavigationChoicesView(frame: CGRect(x: 0, y: 0, width: 360, height: 200))
        view.update(model: rows(3))
        view.selectRow(0)
        view.moveSelection(by: -1)
        XCTAssertEqual(view.selectedIndex, 2)
        view.moveSelection(by: 1)
        XCTAssertEqual(view.selectedIndex, 0)
        view.selectRow(10)
        XCTAssertEqual(view.selectedIndex, 2)
    }

    func testPreferredHeightStopsGrowingAfterTenRows() {
        let ten = NavigationChoicesView.preferredSize(for: rows(10))
        XCTAssertEqual(NavigationChoicesView.preferredSize(for: rows(50)), ten)
        XCTAssertLessThan(NavigationChoicesView.preferredSize(for: rows(2)).height, ten.height)
    }

    private func rows(_ count: Int) -> NavigationChoicesModel {
        NavigationChoicesModel(header: "", rows: (0..<count).map { .init(title: "Row \($0)", subtitle: nil) })
    }

    private func location(_ name: String, url: URL?) -> Location {
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Location(documentID: DocumentID(), url: url, range: TextRange(start: origin, end: origin), displayName: name)
    }
}
