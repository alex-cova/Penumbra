import AppKit
import XCTest
@testable import Penumbra

@MainActor
final class ToolWindowPaletteTests: XCTestCase {
    private var opened: [String] = []

    private func entries() -> [ToolWindowEntry] {
        ["Project", "Terminal", "Problems", "Source Control"].map { title in
            ToolWindowEntry(id: title.lowercased(), title: title) { [weak self] in self?.opened.append(title) }
        }
    }

    func testAnEmptyQueryListsEveryWindowInTheHostsOrder() async {
        let provider = ToolWindowsPaletteProvider(entries: { self.entries() })

        let items = await provider.items(matching: "", limit: 50)

        XCTAssertEqual(items.map(\.title), ["Project", "Terminal", "Problems", "Source Control"])
        XCTAssertEqual(items.map(\.score), items.map(\.score).sorted(by: >), "The host's order is kept")
    }

    func testTypingNarrowsTheListFuzzily() async {
        let provider = ToolWindowsPaletteProvider(entries: { self.entries() })

        let items = await provider.items(matching: "sc", limit: 50)

        XCTAssertEqual(items.first?.title, "Source Control")
        XCTAssertFalse(items.first?.matchedIndices.isEmpty ?? true)
    }

    func testChoosingARowOpensThatWindow() async throws {
        let provider = ToolWindowsPaletteProvider(entries: { self.entries() })

        let items = await provider.items(matching: "", limit: 50)
        try XCTUnwrap(items.first { $0.title == "Problems" }).action()

        XCTAssertEqual(opened, ["Problems"])
    }

    func testTheListIsAskedForOnEveryQuery() async {
        var available = ["Project"]
        let provider = ToolWindowsPaletteProvider(entries: {
            available.map { title in ToolWindowEntry(id: title, title: title) {} }
        })

        let before = await provider.items(matching: "", limit: 50)
        available.append("Debug")
        let after = await provider.items(matching: "", limit: 50)

        XCTAssertEqual(before.map(\.title), ["Project"])
        XCTAssertEqual(after.map(\.title), ["Project", "Debug"], "A window that appears later joins the list")
    }

    func testGoToToolIsNotHandledUntilTheHostSuppliesWindows() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        XCTAssertFalse(textView.perform(.goToTool))
        XCTAssertFalse(controller.isPresented)
    }

    func testGoToToolOpensTheListOfWindows() async throws {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.toolWindowEntriesProvider = { self.entries() }

        XCTAssertTrue(textView.perform(.goToTool))
        XCTAssertEqual(controller.paletteModel.mode, .toolWindows)

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(controller.flatItems.map(\.title), ["Project", "Terminal", "Problems", "Source Control"])
    }

    func testTheActionHasATitleAndIsListedInFindAction() {
        XCTAssertEqual(EditorActionID.goToTool.title, "Go to Tool Window…")
        XCTAssertTrue(CommandRegistry.findActionIDs.contains(.goToTool))
    }
}
