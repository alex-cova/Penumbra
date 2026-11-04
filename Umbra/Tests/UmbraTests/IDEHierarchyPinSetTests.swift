import XCTest
@testable import Umbra

/// The rules Pin Tab has always had, now in one place for both the type and the call hierarchy.
@MainActor
final class IDEHierarchyPinSetTests: XCTestCase {
    private final class Store {
        let name: String
        init(_ name: String) { self.name = name }
    }

    func testNothingIsPinnedAtFirstAndTheLiveViewShows() {
        let pins = IDEHierarchyPinSet<Store>()
        let live = Store("live")
        XCTAssertTrue(pins.isEmpty)
        XCTAssertNil(pins.selectedID)
        XCTAssertTrue(pins.visible(live: live) === live)
    }

    func testPinningKeepsTheCopyAndShowsIt() {
        let pins = IDEHierarchyPinSet<Store>()
        let live = Store("live")
        let copy = Store("copy")
        pins.pin(title: "Type Hierarchy: Foo", store: copy)
        XCTAssertFalse(pins.isEmpty)
        XCTAssertEqual(pins.pins.map(\.title), ["Type Hierarchy: Foo"])
        XCTAssertEqual(pins.selectedID, pins.pins.first?.id)
        XCTAssertTrue(pins.visible(live: live) === copy, "the pinned copy shows, not the live one")
    }

    /// Only the live view can be pinned; a second Pin Tab while a pin shows does nothing.
    func testPinningWhileAPinShowsDoesNothing() {
        let pins = IDEHierarchyPinSet<Store>()
        pins.pin(title: "first", store: Store("a"))
        pins.pin(title: "second", store: Store("b"))
        XCTAssertEqual(pins.pins.map(\.title), ["first"])
    }

    func testBackToTheLiveViewAllowsAnotherPin() {
        let pins = IDEHierarchyPinSet<Store>()
        let live = Store("live")
        pins.pin(title: "first", store: Store("a"))
        pins.selectedID = nil
        XCTAssertTrue(pins.visible(live: live) === live)
        pins.pin(title: "second", store: Store("b"))
        XCTAssertEqual(pins.pins.map(\.title), ["first", "second"])
        XCTAssertEqual(pins.selectedID, pins.pins.last?.id)
    }

    func testUnpinningTheShownPinReturnsToTheLiveView() {
        let pins = IDEHierarchyPinSet<Store>()
        let live = Store("live")
        pins.pin(title: "first", store: Store("a"))
        let shown = try! XCTUnwrap(pins.selectedID)
        pins.unpin(shown)
        XCTAssertTrue(pins.isEmpty)
        XCTAssertNil(pins.selectedID)
        XCTAssertTrue(pins.visible(live: live) === live)
    }

    func testUnpinningAnotherPinKeepsTheSelection() {
        let pins = IDEHierarchyPinSet<Store>()
        pins.pin(title: "first", store: Store("a"))
        let first = try! XCTUnwrap(pins.selectedID)
        pins.selectedID = nil
        pins.pin(title: "second", store: Store("b"))
        let second = try! XCTUnwrap(pins.selectedID)
        pins.unpin(first)
        XCTAssertEqual(pins.pins.map(\.title), ["second"])
        XCTAssertEqual(pins.selectedID, second)
    }

    func testRemoveAllClearsPinsAndSelection() {
        let pins = IDEHierarchyPinSet<Store>()
        pins.pin(title: "first", store: Store("a"))
        pins.selectedID = nil
        pins.pin(title: "second", store: Store("b"))
        pins.removeAll()
        XCTAssertTrue(pins.isEmpty)
        XCTAssertNil(pins.selectedID)
    }

    func testAWorkspaceKeepsTheTwoKindsApart() {
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer { IDEWorkspace.isSessionPersistenceEnabled = true }
        let workspace = IDEWorkspace()
        workspace.typePins.pin(title: "t", store: workspace.typeHierarchy.copy())
        XCTAssertTrue(workspace.showsTypeHierarchyTab)
        XCTAssertFalse(workspace.showsCallHierarchyTab)
        XCTAssertTrue(workspace.callPins.isEmpty)
        workspace.closeAllHierarchies()
        XCTAssertFalse(workspace.showsTypeHierarchyTab)
        XCTAssertTrue(workspace.typePins.isEmpty)
    }
}
