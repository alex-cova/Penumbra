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

    func testQuickOpenShowsTabStripNotRecentFilesNavigationChrome() {
        let textView = makeFocusedTextView(text: "x")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let controller = CommandPaletteController(textView: textView, overlayContainer: container)
        controller.fileIndex = makeFileIndex(["Main.swift"])
        controller.navigationDestinationsProvider = {
            [RecentFilesDestination(id: "project", title: "Project", action: {})]
        }

        XCTAssertTrue(textView.perform(.quickOpenFile))
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.paletteModel.mode, .quickOpen)
        XCTAssertEqual(controller.currentTab, .files)
        XCTAssertFalse(controller.paletteView.tabs.isEmpty)
        XCTAssertFalse(controller.paletteView.showsNavigationChrome)
    }

    func testQuickOpenListsFilesAfterRecentFilesNavigationChrome() async {
        let textView = makeFocusedTextView(text: "x")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let controller = CommandPaletteController(textView: textView, overlayContainer: container)
        controller.fileIndex = makeFileIndex(["Main.swift", "Other.swift"])

        controller.presentRecentFiles()
        controller.dismiss()
        controller.presentQuickOpen()
        await waitForRows(controller)

        XCTAssertGreaterThanOrEqual(controller.flatItems.count, 2)
        controller.paletteView.layoutSubtreeIfNeeded()
        let table = controller.paletteView.subviews
            .compactMap { $0 as? NSScrollView }
            .first(where: { ($0.documentView as? NSTableView) != nil })?
            .documentView as? NSTableView
        XCTAssertNotNil(table)
        XCTAssertGreaterThan(table?.frame.height ?? 0, 0)
    }

    func testQuickOpenArrowKeysMoveSelectionThroughFieldEditor() async {
        let textView = makeFocusedTextView(text: "x")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        let controller = CommandPaletteController(textView: textView, overlayContainer: container)
        controller.fileIndex = makeFileIndex(["Main.swift", "Other.swift", "Third.swift"])

        controller.presentQuickOpen()
        await waitForRows(controller)
        XCTAssertGreaterThanOrEqual(controller.flatItems.count, 3)
        XCTAssertEqual(controller.paletteModel.selectedIndex, 0)

        container.layoutSubtreeIfNeeded()
        controller.paletteView.layoutSubtreeIfNeeded()
        controller.paletteView.focusQueryField()
        try? await Task.sleep(nanoseconds: 20_000_000)

        guard let field = queryField(in: controller.paletteView),
              let editor = window.fieldEditor(true, for: field) as? NSTextView else {
            return XCTFail("Expected an editable query field with a field editor")
        }

        XCTAssertTrue(
            controller.paletteView.control(
                field,
                textView: editor,
                doCommandBy: #selector(NSResponder.moveDown(_:))
            )
        )
        XCTAssertEqual(controller.paletteModel.selectedIndex, 1)

        XCTAssertTrue(
            controller.paletteView.control(
                field,
                textView: editor,
                doCommandBy: #selector(NSResponder.moveUp(_:))
            )
        )
        XCTAssertEqual(controller.paletteModel.selectedIndex, 0)
    }

    func testQuickOpenTabCyclesCategoryTabs() async {
        let textView = makeFocusedTextView(text: "x")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let controller = CommandPaletteController(textView: textView, overlayContainer: container)
        controller.fileIndex = makeFileIndex(["Main.swift"])
        controller.symbolIndex = SymbolIndex()

        controller.presentQuickOpen()
        XCTAssertEqual(controller.currentTab, .files)
        let tabs = controller.paletteView.tabs
        guard tabs.count > 1, let filesIndex = tabs.firstIndex(of: .files) else {
            return XCTFail("Expected multiple tabs including Files")
        }
        let nextTab = tabs[(filesIndex + 1) % tabs.count]

        guard let field = queryField(in: controller.paletteView) else {
            return XCTFail("Expected query field")
        }
        let editor = NSWindow().fieldEditor(true, for: field) as! NSTextView
        XCTAssertTrue(
            controller.paletteView.control(
                field,
                textView: editor,
                doCommandBy: #selector(NSResponder.insertTab(_:))
            )
        )
        XCTAssertEqual(controller.currentTab, nextTab)
    }

    private func queryField(in paletteView: CommandPaletteView) -> NSTextField? {
        paletteView.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }
    }

    func testQuickOpenFooterShowsShortcutLegend() async {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.fileIndex = makeFileIndex(["Main.swift", "Other.swift"])
        controller.symbolIndex = SymbolIndex()

        controller.presentQuickOpen()
        await waitForRows(controller)

        let legend = controller.paletteView.footerShortcutLegend.map(\.title)
        XCTAssertTrue(legend.contains("Open"))
        XCTAssertTrue(legend.contains("Close"))
        XCTAssertTrue(legend.contains("Next tab"))
    }

    func testQuickOpenFooterShowsSplitHintWhenAvailable() async {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.fileIndex = makeFileIndex(["Main.swift"])
        controller.onOpenFileInSplit = { _ in }

        controller.presentQuickOpen()
        await waitForRows(controller)

        let legend = controller.paletteView.footerShortcutLegend
        XCTAssertTrue(legend.contains { $0.keys == "⇧↩" && $0.title == "Open in Split" })
    }

    func testRecentFilesFooterShowsNavigationHints() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.navigationDestinationsProvider = {
            [RecentFilesDestination(id: "project", title: "Project", action: {})]
        }

        controller.presentRecentFiles()

        let legend = controller.paletteView.footerShortcutLegend.map(\.title)
        XCTAssertTrue(legend.contains("Navigate"))
        XCTAssertTrue(legend.contains("Edited only"))
    }

    func testQuickOpenReinstallsOverlayAfterBackdropDetaches() {
        let textView = makeFocusedTextView(text: "x")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let controller = CommandPaletteController(textView: textView, overlayContainer: container)
        controller.fileIndex = makeFileIndex(["Main.swift"])

        controller.presentQuickOpen()
        XCTAssertFalse(container.subviews.isEmpty)

        container.subviews.forEach { $0.removeFromSuperview() }
        controller.presentQuickOpen()

        XCTAssertTrue(
            container.subviews.contains { !$0.isHidden },
            "Go to File should reinstall the backdrop when the overlay host was rebuilt"
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

    func testLineSuffixOpensTheFileAtThatLine() async {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.fileIndex = makeFileIndex(["src/ApiKeyController.java", "src/Other.java"])
        var openedAt: [(String, PaletteLineTarget)] = []
        controller.onOpenFileAtLine = { openedAt.append(($0.lastPathComponent, $1)) }

        controller.presentQuickOpen()
        controller.paletteModel.query = "AKC:42:7"
        controller.selectTab(.files)
        await waitForRows(controller)

        XCTAssertEqual(controller.flatItems.first?.title, "ApiKeyController.java")
        XCTAssertEqual(controller.flatItems.first?.footer, "src/ApiKeyController.java:42:7")
        controller.activateSelection()
        XCTAssertEqual(openedAt.first?.0, "ApiKeyController.java")
        XCTAssertEqual(openedAt.first?.1, PaletteLineTarget(line: 42, column: 7))
    }

    func testReopeningGoToFileRestoresTheLastQuery() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.fileIndex = makeFileIndex(["Main.swift"])

        controller.presentQuickOpen()
        controller.paletteModel.query = "Mai"
        controller.dismiss()
        controller.presentQuickOpen()
        XCTAssertEqual(controller.paletteModel.query, "Mai")
        XCTAssertEqual(controller.paletteView.query, "Mai")

        controller.dismiss()
        controller.restoresLastQuery = false
        controller.presentQuickOpen()
        XCTAssertEqual(controller.paletteModel.query, "")
    }

    func testIndexedFileRowsCarryTheirSourceRoot() async {
        let index = PaletteFileIndex(entries: [
            PaletteFileIndex.Entry(
                url: URL(fileURLWithPath: "/proj/src/test/java/FooTest.java"),
                relativePath: "src/test/java/FooTest.java",
                location: "src/test/java",
                module: "proj.test",
                icon: PaletteIcon(systemName: "doc"),
                sourceRoot: .tests
            )
        ])
        let items = await FilesPaletteProvider(index: { index }, onOpen: { _ in }).items(matching: "Foo", limit: 5)
        XCTAssertEqual(items.first?.sourceRoot, .tests)
        XCTAssertEqual(items.first?.sourceRoot?.isTest, true)
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

    func testPresentedPaletteBlocksScrollWheelFromReachingEditor() {
        let text = (1...80).map { "line \($0)" }.joined(separator: "\n")
        let textView = makeFocusedTextView(text: text)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let controller = CommandPaletteController(textView: textView, overlayContainer: container)

        textView.contentOffset = CGPoint(x: 0, y: 120)
        let offsetBefore = textView.contentOffset

        controller.presentRecentFiles()
        container.layoutSubtreeIfNeeded()
        controller.paletteView.layoutSubtreeIfNeeded()

        let backdrop = container.subviews.first { !$0.isHidden }
        XCTAssertNotNil(backdrop)
        backdrop?.scrollWheel(with: makeScrollWheelEvent(deltaY: 3))

        XCTAssertEqual(textView.contentOffset, offsetBefore, "Backdrop should swallow wheel events")

        controller.paletteView.scrollWheel(with: makeScrollWheelEvent(deltaY: 3))
        XCTAssertEqual(textView.contentOffset, offsetBefore, "Palette chrome should not forward wheel events to the editor")
    }

    private func makeScrollWheelEvent(deltaY: Int32) -> NSEvent {
        let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        )!
        return NSEvent(cgEvent: cgEvent)!
    }
}
