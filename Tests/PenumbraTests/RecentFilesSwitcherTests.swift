import AppKit
import XCTest
@testable import Penumbra

/// The ⌘E Recent Files palette as IntelliJ's switcher: second-row preselection, removal,
/// tool-window filtering, the edited-only filter, and the fall-through to Go to File.
@MainActor
final class RecentFilesSwitcherTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")

    func testSelectsTheSecondFileWhenTheFirstIsInTheActiveEditor() async {
        let controller = makeController(files: ["A.swift", "B.swift", "C.swift"], active: "A.swift")

        controller.presentRecentFiles()
        await waitUntil { controller.flatItems.count == 3 }

        XCTAssertEqual(controller.paletteModel.selectedIndex, 1)
    }

    func testSelectsTheFirstFileWhenTheActiveEditorIsElsewhere() async {
        let controller = makeController(files: ["A.swift", "B.swift"], active: "Other.swift")

        controller.presentRecentFiles()
        await waitUntil { controller.flatItems.count == 2 }

        XCTAssertEqual(controller.paletteModel.selectedIndex, 0)
    }

    func testTypingKeepsTheBestMatchSelected() async {
        let controller = makeController(files: ["A.swift", "AB.swift"], active: "A.swift")

        controller.presentRecentFiles()
        controller.paletteView.onQueryChange?("A")
        await waitUntil { controller.flatItems.count == 2 }

        XCTAssertEqual(controller.paletteModel.selectedIndex, 0)
    }

    func testRemovingAFileAsksTheHostAndKeepsTheSelectionIndex() async {
        var removed: [String] = []
        let controller = makeController(files: ["A.swift", "B.swift", "C.swift"], active: "A.swift")
        controller.onRemoveRecentFile = { removed.append($0.lastPathComponent) }

        controller.presentRecentFiles()
        await waitUntil { controller.flatItems.count == 3 }
        controller.removeSelection()

        XCTAssertEqual(removed, ["B.swift"])
        XCTAssertEqual(controller.flatItems.map(\.title), ["A.swift", "C.swift"])
        XCTAssertEqual(controller.paletteModel.selectedIndex, 1)
    }

    func testRemovingTheLastFileMovesToTheToolWindows() async {
        let controller = makeController(files: ["A.swift"], active: nil)
        controller.onRemoveRecentFile = { _ in }
        controller.navigationDestinationsProvider = {
            [RecentFilesDestination(id: "terminal", title: "Terminal", action: {})]
        }

        controller.presentRecentFiles()
        await waitUntil { controller.flatItems.count == 1 }
        controller.removeSelection()

        XCTAssertTrue(controller.flatItems.isEmpty)
        XCTAssertEqual(controller.paletteView.navigationPane, .destinations)
    }

    func testRemovingOnAToolWindowHidesIt() async {
        let closed = ClosedFlag()
        let controller = makeController(files: [], active: nil)
        controller.navigationDestinationsProvider = {
            [RecentFilesDestination(id: "terminal", title: "Terminal", action: {}, close: { closed.value = true })]
        }

        controller.presentRecentFiles()
        controller.paletteView.navigationPane = .destinations
        controller.removeSelection()

        XCTAssertTrue(closed.value)
    }

    func testQueryFiltersToolWindowsAndFocusesThemWhenNoFileMatches() async {
        let controller = makeController(files: ["A.swift"], active: nil)
        controller.navigationDestinationsProvider = {
            [
                RecentFilesDestination(id: "explorer", title: "Explorer", action: {}),
                RecentFilesDestination(id: "terminal", title: "Terminal", action: {})
            ]
        }

        controller.presentRecentFiles()
        controller.paletteView.onQueryChange?("term")
        await waitUntil { controller.paletteView.navigationPane == .destinations }

        XCTAssertEqual(controller.paletteView.navigationDestinations.map(\.title), ["Terminal"])
        XCTAssertTrue(controller.flatItems.isEmpty)
    }

    func testEditedOnlyShowsOnlyEditedFiles() async {
        let controller = makeController(files: ["A.swift", "B.swift"], active: nil, edited: ["B.swift"])

        controller.presentRecentFiles()
        await waitUntil { controller.flatItems.count == 2 }
        controller.paletteView.onToggleEditedOnly?()
        await waitUntil { controller.flatItems.count == 1 }

        XCTAssertEqual(controller.flatItems.map(\.title), ["B.swift"])
        XCTAssertTrue(controller.paletteView.editedOnly)
    }

    func testRowsCarryVersionControlStatus() async {
        let controller = CommandPaletteController(textView: makeFocusedTextView(text: "x"))
        let url = root.appendingPathComponent("A.swift")
        controller.recentFileEntriesProvider = { [PaletteFileEntry(url: url, status: .modified)] }

        controller.presentRecentFiles()
        await waitUntil { !controller.flatItems.isEmpty }

        XCTAssertEqual(controller.flatItems.first?.fileStatus, .modified)
        XCTAssertEqual(controller.flatItems.first?.fileURL, url)
    }

    func testReturnWithNoRecentMatchContinuesInGoToFile() async {
        let controller = makeController(files: ["A.swift"], active: nil)
        controller.fileIndex = PaletteFileIndex(entries: [
            PaletteFileIndex.Entry(
                url: root.appendingPathComponent("Zebra.swift"),
                relativePath: "Zebra.swift",
                location: nil,
                module: nil,
                icon: PaletteIcon(systemName: "doc")
            )
        ])

        controller.presentRecentFiles()
        controller.paletteView.onQueryChange?("zeb")
        await waitUntil { controller.paletteView.emptyStateMessage == "No results" && controller.flatItems.isEmpty }
        controller.activateSelection()

        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.paletteModel.mode, .quickOpen)
        XCTAssertEqual(controller.paletteView.query, "zeb")
    }

    func testDeleteKeyRemovesOnlyWhenTheQueryIsEmpty() async {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        let controller = makeController(files: ["A.swift", "B.swift"], active: nil, container: container)
        var removed = 0
        controller.onRemoveRecentFile = { _ in removed += 1 }

        controller.presentRecentFiles()
        await waitUntil { controller.flatItems.count == 2 }
        guard let field = controller.paletteView.subviews.compactMap({ $0 as? NSTextField }).first(where: \.isEditable),
              let editor = window.fieldEditor(true, for: field) as? NSTextView else {
            return XCTFail("Expected an editable query field with a field editor")
        }
        let delete = #selector(NSResponder.deleteBackward(_:))

        field.stringValue = "A"
        XCTAssertFalse(controller.paletteView.control(field, textView: editor, doCommandBy: delete))
        XCTAssertEqual(removed, 0)

        field.stringValue = ""
        XCTAssertTrue(controller.paletteView.control(field, textView: editor, doCommandBy: delete))
        XCTAssertEqual(removed, 1)
    }

    func testRecentLocationsActionNeedsAProviderAndALineOpener() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)

        XCTAssertFalse(textView.perform(.recentLocations))

        controller.recentLocationsProvider = { [] }
        controller.onOpenFileAtLine = { _, _ in }
        XCTAssertTrue(textView.perform(.recentLocations))
        XCTAssertEqual(controller.paletteModel.mode, .recentLocations)
    }

    func testStatusColorsFollowTheAppearance() {
        let color = paletteFileStatusColor(for: .modified)
        var dark: NSColor?
        var light: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { dark = color.usingColorSpace(.sRGB) }
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { light = color.usingColorSpace(.sRGB) }

        XCTAssertNotNil(dark)
        XCTAssertNotEqual(dark, light)
    }

    // MARK: - Helpers

    private func makeController(
        files: [String],
        active: String?,
        edited: Set<String> = [],
        container: NSView? = nil
    ) -> CommandPaletteController {
        let controller = CommandPaletteController(textView: makeFocusedTextView(text: "x"), overlayContainer: container)
        let root = self.root
        controller.recentFileEntriesProvider = {
            files.map { PaletteFileEntry(url: root.appendingPathComponent($0), isEdited: edited.contains($0)) }
        }
        if let active {
            let url = root.appendingPathComponent(active)
            controller.activeDocumentURLProvider = { url }
        }
        return controller
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<150 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
private final class ClosedFlag {
    var value = false
}
