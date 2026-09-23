import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

/// `CommandPaletteController` wiring: built-in action registration, presentation state,
/// keymap-action routing, provider selection, and fuzzy match plumbing.
@MainActor
final class CommandPaletteControllerTests: XCTestCase {
    func testRegistersBuiltInActionsWithShortcutsFromKeymap() {
        let textView = makeFocusedTextView(text: "x")
        textView.keymap = .intelliJ
        let controller = CommandPaletteController(textView: textView)

        let joinLines = controller.commandRegistry.command(id: "action.\(EditorActionID.joinLines.rawValue)")
        XCTAssertNotNil(joinLines)
        XCTAssertEqual(joinLines?.shortcutDisplay, "\u{2303}\u{21E7}J")
    }

    func testSearchEverywhereActionPresentsThePalette() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        XCTAssertFalse(controller.isPresented)

        XCTAssertTrue(textView.perform(.findAction))
        XCTAssertTrue(controller.isPresented)

        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
    }

    func testSurroundWithActionOnlyPresentsWithANonEmptySelection() {
        let textView = makeFocusedTextView(text: "value")
        let controller = CommandPaletteController(textView: textView)

        textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertTrue(textView.perform(.surroundWith))
        XCTAssertFalse(controller.isPresented, "No selection -> nothing to surround")

        textView.selectedRange = NSRange(location: 0, length: 5)
        XCTAssertTrue(textView.perform(.surroundWith))
        XCTAssertTrue(controller.isPresented)
    }

    func testCommandsProviderPopulatesFuzzyMatchIndices() async {
        let registry = CommandRegistry()
        registry.register(EditorCommand(id: "c1", title: "Reformat Code", group: "Editor", action: {}))
        registry.register(EditorCommand(id: "c2", title: "Reindent Lines", group: "Editor", action: {}))
        let provider = CommandsPaletteProvider(registry: registry)

        let items = await provider.items(matching: "rc", limit: 10)
        XCTAssertEqual(items.first?.title, "Reformat Code")
        XCTAssertFalse(items.first?.matchedIndices.isEmpty ?? true, "Match indices drive the row highlight")
    }

    func testGoToLineActionPresentsThePaletteSeededWithColon() {
        let textView = makeFocusedTextView(text: "alpha\nbeta\ngamma\n")
        let controller = CommandPaletteController(textView: textView)
        XCTAssertFalse(controller.isPresented)

        XCTAssertTrue(textView.perform(.goToLine))
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.paletteModel.mode, .goToLine)
        XCTAssertEqual(controller.paletteModel.query, ":")
    }

    func testFindInFilesActionIsUnhandledWithoutAProjectSearchEngine() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)

        XCTAssertFalse(textView.perform(.findInFiles), "No engine/root wired -- a host's own UI should get a chance")
        XCTAssertFalse(controller.isPresented)
    }

    func testFindInFilesActionPresentsThePaletteOnceWiredWithAnEngineAndRoot() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.projectSearchEngine = ProjectSearchEngine()
        controller.workspaceRoot = URL(fileURLWithPath: "/tmp")

        XCTAssertTrue(textView.perform(.findInFiles))
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.paletteModel.mode, .findInFiles)
    }

    func testActionHandlerChainingPreservesAPreviousHandler() {
        let textView = makeFocusedTextView(text: "x")
        var previousSaw: EditorActionID?
        textView.editorActionHandler = { action in
            previousSaw = action
            return false
        }
        _ = CommandPaletteController(textView: textView)

        // A non-palette action falls through the controller to the previous handler.
        _ = textView.perform(.goToImplementation)
        XCTAssertEqual(previousSaw, .goToImplementation)
    }

    /// `CommandRegistry.findActionIDs` is a hand-maintained list, not derived automatically from
    /// `EditorActionID.builtInTitles` — a new action with a title (and so a `title` shown
    /// anywhere a `EditorActionID` is listed) silently stays invisible in Find Action unless it's
    /// also added here. This locks the two in sync so that gap can't reopen unnoticed. If this
    /// fails after adding a new built-in action, add the ID to `findActionIDs`; if it fails after
    /// adding a title-less internal ID, add it to `builtInTitles` or exclude it deliberately here.
    func testFindActionIDsCoversEveryBuiltInTitledAction() {
        let titled = Set(EditorActionID.builtInTitles.keys)
        let registered = Set(CommandRegistry.findActionIDs)
        let missing = titled.subtracting(registered)
        XCTAssertTrue(missing.isEmpty, "Missing from CommandRegistry.findActionIDs: \(missing.map(\.rawValue).sorted())")
    }

    func testNewLineAndCommentCommandsAreRegisteredWithTheirKeymapShortcuts() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)

        let toggleComment = controller.commandRegistry.command(id: "action.\(EditorActionID.toggleComment.rawValue)")
        XCTAssertNotNil(toggleComment)
        XCTAssertEqual(toggleComment?.shortcutDisplay, "\u{2318}/")

        let insertBelow = controller.commandRegistry.command(id: "action.\(EditorActionID.insertLineBelow.rawValue)")
        XCTAssertNotNil(insertBelow)

        let insertAbove = controller.commandRegistry.command(id: "action.\(EditorActionID.insertLineAbove.rawValue)")
        XCTAssertNotNil(insertAbove)

        // No default keybinding — still discoverable via Find Action, just with no shortcut shown.
        let sortAscending = controller.commandRegistry.command(id: "action.\(EditorActionID.sortLinesAscending.rawValue)")
        XCTAssertNotNil(sortAscending)
        XCTAssertNil(sortAscending?.shortcutDisplay)
    }

    func testOverlayInstallsOnProvidedContainerRatherThanTextView() {
        let textView = makeFocusedTextView(text: "x")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let controller = CommandPaletteController(textView: textView, overlayContainer: container)

        XCTAssertTrue(textView.perform(.findAction))
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(
            container.subviews.contains { $0.subviews.contains { $0 is CommandPaletteView } },
            "Backdrop + CommandPaletteView should live on the overlay container"
        )
    }

    func testBindActionsOnASecondTextViewPresentsTheSharedPalette() {
        let first = makeFocusedTextView(text: "one")
        let second = makeFocusedTextView(text: "two")
        let controller = CommandPaletteController(textView: first)
        controller.bindActions(to: second)

        XCTAssertTrue(second.perform(.findAction))
        XCTAssertTrue(controller.isPresented)
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
    }

    // MARK: - Tabs, file index, alternate action

    private func makeFileIndex(_ paths: [String]) -> PaletteFileIndex {
        let root = URL(fileURLWithPath: "/proj")
        return PaletteFileIndex(entries: paths.map {
            PaletteFileIndex.Entry(
                url: root.appendingPathComponent($0),
                relativePath: $0,
                location: nil,
                module: "proj.main",
                icon: PaletteIcon(systemName: "doc")
            )
        })
    }

    private func waitForRows(_ controller: CommandPaletteController) async {
        for _ in 0..<100 where controller.flatItems.isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testTabsOnlyOfferSourcesTheHostWired() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        XCTAssertEqual(controller.availableTabs, [.all, .actions])

        controller.fileIndex = makeFileIndex(["a.swift"])
        XCTAssertEqual(controller.availableTabs, [.all, .files, .actions])

        controller.projectSearchEngine = ProjectSearchEngine()
        controller.workspaceRoot = URL(fileURLWithPath: "/proj")
        XCTAssertEqual(controller.availableTabs, [.all, .files, .actions, .text])
    }

    func testSelectTabSwitchesModeAndKeepsTheQuery() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.fileIndex = makeFileIndex(["a.swift"])
        controller.presentQuickOpen()
        XCTAssertEqual(controller.currentTab, .files)

        controller.paletteModel.query = "abc"
        controller.selectTab(.actions)

        XCTAssertEqual(controller.paletteModel.mode, .commands)
        XCTAssertEqual(controller.currentTab, .actions)
        XCTAssertEqual(controller.paletteModel.query, "abc")

        controller.selectTab(.classes)
        XCTAssertEqual(controller.currentTab, .actions, "A tab without a source is ignored")
    }

    func testGoToLineHasNoTab() {
        let textView = makeFocusedTextView(text: "a\nb\n")
        let controller = CommandPaletteController(textView: textView)
        controller.presentGoToLine()
        XCTAssertNil(controller.currentTab)
    }

    func testFindInFilesActionIsUnhandledWhenTheHostOwnsThePanel() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.projectSearchEngine = ProjectSearchEngine()
        controller.workspaceRoot = URL(fileURLWithPath: "/tmp")
        controller.handlesFindInFilesAction = false

        XCTAssertFalse(textView.perform(.findInFiles))
        XCTAssertFalse(controller.isPresented)
    }

    func testIndexedFileRowsCarryColumnsAndOpenInSplit() async {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.fileIndex = makeFileIndex(["src/ApiKeyController.java", "src/Other.java"])
        var opened: [String] = []
        var split: [String] = []
        controller.onOpenFile = { opened.append($0.lastPathComponent) }
        controller.onOpenFileInSplit = { split.append($0.lastPathComponent) }

        controller.presentQuickOpen()
        controller.paletteModel.query = "AKC"
        controller.selectTab(.files)
        await waitForRows(controller)

        let item = controller.flatItems.first
        XCTAssertEqual(item?.title, "ApiKeyController.java")
        XCTAssertEqual(item?.trailing, "proj.main")
        XCTAssertEqual(item?.footer, "src/ApiKeyController.java")
        XCTAssertEqual(item?.matchedIndices, [0, 3, 6])
        XCTAssertNotNil(item?.alternateAction)

        controller.activateSelection(alternate: true)
        XCTAssertEqual(split, ["ApiKeyController.java"])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(controller.isPresented)
    }

    func testFileRowsOfferNoAlternateActionWithoutASplitHandler() async {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.fileIndex = makeFileIndex(["a.swift"])
        controller.presentQuickOpen()
        await waitForRows(controller)

        XCTAssertNil(controller.flatItems.first?.alternateAction)
        controller.activateSelection(alternate: true)
        XCTAssertTrue(controller.isPresented, "⇧↩ on a row without a secondary action does nothing")
    }

    func testFilesProviderNarrowingMatchesAColdSearch() async {
        let index = makeFileIndex(["a/ApiKeyService.java", "a/ApiKeyFilter.java", "b/Unrelated.java"])
        let provider = FilesPaletteProvider(index: { index }, onOpen: { _ in })
        _ = await provider.items(matching: "Api", limit: 10)
        let narrowed = await provider.items(matching: "ApiKeyS", limit: 10)
        let cold = await FilesPaletteProvider(index: { index }, onOpen: { _ in }).items(matching: "ApiKeyS", limit: 10)
        XCTAssertEqual(narrowed.map(\.id), cold.map(\.id))
        XCTAssertEqual(narrowed.map(\.title), ["ApiKeyService.java"])
    }
}
