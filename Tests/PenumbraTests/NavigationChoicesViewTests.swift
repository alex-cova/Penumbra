@preconcurrency import AppKit
import EditorIntelligence
@testable import Penumbra
import XCTest

@MainActor
final class NavigationChoicesViewTests: XCTestCase {
    func testModelLabelsEachLocationWithItsFolderFileAndLine() {
        let locations = [
            location("Circle", url: URL(fileURLWithPath: "/p/shapes/Circle.java"), line: 6),
            location("Circle(double radius)", url: URL(fileURLWithPath: "/p/shapes/Circle.java"), line: 11),
            location("Square", url: nil)
        ]
        let model = NavigationChoicesModel(identifier: "Shape", locations: locations)
        XCTAssertEqual(model.header, "3 targets for Shape")
        XCTAssertEqual(model.rows, [
            .init(title: "Circle", subtitle: "shapes/Circle.java", line: 7, symbolName: "c.square.fill"),
            .init(title: "Circle(double radius)", subtitle: "shapes/Circle.java", line: 12, symbolName: "m.square.fill"),
            .init(title: "Square", subtitle: nil, line: nil, symbolName: "c.square.fill")
        ])
    }

    func testAPackageRowHasAFolderIconAndNoLine() {
        let location = Location(
            documentID: DocumentID(), url: URL(fileURLWithPath: "/p/src/main/java/com/acme"),
            range: TextRange(start: TextPosition(line: 0, column: 0, utf16Offset: 0), end: TextPosition(line: 0, column: 0, utf16Offset: 0)),
            displayName: "src/main/java/com/acme", target: .directory
        )
        let row = NavigationChoicesModel(identifier: "acme", locations: [location, location]).rows[0]
        XCTAssertEqual(row.symbolName, "folder.fill")
        XCTAssertNil(row.line)
        XCTAssertNil(row.subtitle)
    }

    func testTheWidthFollowsTheLongestTitleWithinLimits() {
        let short = NavigationChoicesView.preferredSize(for: rows(3))
        XCTAssertEqual(short.width, NavigationChoicesView.minimumWidth)
        let long = NavigationChoicesModel(header: "", rows: [
            .init(title: "BadRequestException(String message, long errorCode, Exception cause, Map<String, Object> details)", subtitle: nil)
        ])
        XCTAssertEqual(NavigationChoicesView.preferredSize(for: long).width, NavigationChoicesView.maximumWidth)
        let medium = NavigationChoicesModel(header: "", rows: [
            .init(title: "BadRequestException(String key, String message)", subtitle: nil)
        ])
        let width = NavigationChoicesView.preferredSize(for: medium).width
        XCTAssertGreaterThan(width, NavigationChoicesView.minimumWidth)
        XCTAssertLessThan(width, NavigationChoicesView.maximumWidth)
    }

    /// Draws the popup the way a ⌘-click on a class with three constructors shows it. Set
    /// `NAVIGATION_POPUP_PNG` to a path to keep the picture.
    func testRendersTheThreeConstructorsPopup() throws {
        let model = NavigationChoicesModel(header: "", rows: [
            .init(title: "BadRequestException(String key, String message)", subtitle: "exception/BadRequestException.java", line: 14, symbolName: "m.square.fill"),
            .init(title: "BadRequestException(String message, long errorCode)", subtitle: "exception/BadRequestException.java", line: 19, symbolName: "m.square.fill"),
            .init(title: "BadRequestException(String message, Exception cause)", subtitle: "exception/BadRequestException.java", line: 24, symbolName: "m.square.fill")
        ])
        var shown = model
        shown.header = "3 targets for BadRequestException"
        let size = NavigationChoicesView.preferredSize(for: shown)
        let view = NavigationChoicesView(frame: CGRect(origin: .zero, size: size))
        view.update(model: shown)
        view.selectRow(0)
        view.layoutSubtreeIfNeeded()
        let canvas = NSView(frame: CGRect(x: 0, y: 0, width: size.width + 40, height: size.height + 40))
        canvas.addSubview(view)
        view.frame.origin = CGPoint(x: 20, y: 20)
        canvas.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["NAVIGATION_POPUP_PNG"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertGreaterThan(png.count, 1_000)
        XCTAssertEqual(view.selectedIndex, 0)
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

    private func location(_ name: String, url: URL?, line: Int = 0) -> Location {
        let origin = TextPosition(line: line, column: 0, utf16Offset: 0)
        return Location(documentID: DocumentID(), url: url, range: TextRange(start: origin, end: origin), displayName: name)
    }
}
