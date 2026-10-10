import Foundation
import JavaIntelligence
import Penumbra
import SwiftUI
import XCTest
@testable import Umbra

/// What the modules put in the toolbar, the status bar, the View menu and the bottom panel, and that a
/// module nobody wrote into the app's list shows up in all of them once it is registered.
@MainActor
final class IDEModuleContributionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDELanguageModules.unregister(id: FakeRubyModule.id)
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private func ids(_ items: [IDEToolbarItem]) -> [String] { items.map(\.id) }

    private func button(_ id: String, in items: [IDEToolbarItem]) -> IDEToolbarItem.Button? {
        for item in items where item.id == id {
            if case .button(let button) = item.content { return button }
        }
        return nil
    }

    // MARK: Toolbar

    func testAFileOfNoParticularLanguageGetsOnlyTheRunConfigurationPicker() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "swift"
        XCTAssertEqual(ids(workspace.toolbarItems()), ["java.runConfigurations"])
    }

    func testAMarkdownFileGetsItsPreviewButtonAndTheExportOnceThePreviewShows() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "markdown"
        XCTAssertEqual(ids(workspace.toolbarItems()), ["java.runConfigurations", "markdown.preview"])
        let toggle = button("markdown.preview", in: workspace.toolbarItems())
        XCTAssertEqual(toggle?.systemImage, "play.fill")
        XCTAssertEqual(toggle?.help, "Toggle Markdown Preview")
        XCTAssertEqual(toggle?.isActive, false)

        workspace.isMarkdownPreviewVisible = true
        XCTAssertEqual(ids(workspace.toolbarItems()), ["java.runConfigurations", "markdown.exportPDF", "markdown.preview"])
        XCTAssertEqual(button("markdown.preview", in: workspace.toolbarItems())?.systemImage, "stop.fill")
        XCTAssertEqual(button("markdown.preview", in: workspace.toolbarItems())?.isActive, true)
    }

    func testJSONAndCSVEachGetTheirOwnToggle() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "json"
        XCTAssertEqual(ids(workspace.toolbarItems()), ["java.runConfigurations", "json.diagram"])
        XCTAssertEqual(button("json.diagram", in: workspace.toolbarItems())?.help, "Toggle JSON Diagram")
        workspace.isJSONDiagramVisible = true
        XCTAssertEqual(button("json.diagram", in: workspace.toolbarItems())?.isActive, true)

        for language in ["csv", "tsv"] {
            workspace.statusLanguage = language
            XCTAssertEqual(ids(workspace.toolbarItems()), ["java.runConfigurations", "csv.table"], language)
            XCTAssertEqual(button("csv.table", in: workspace.toolbarItems())?.help, "Toggle CSV Table")
        }
    }

    func testAJavaFileThatCanRunGetsRunDebugStopAndTestsInTheOldOrder() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "java"
        workspace.runFileCanRun = true
        workspace.javaFileCanTest = true
        let items = workspace.toolbarItems()
        XCTAssertEqual(ids(items), ["java.runConfigurations", "java.run", "java.debug", "java.stop", "java.runTests"])
        XCTAssertEqual(button("java.run", in: items)?.help, "Run Java file")
        XCTAssertEqual(button("java.debug", in: items)?.isEnabled, false, "Debugging needs a Gradle project")
        XCTAssertEqual(button("java.stop", in: items)?.isEnabled, false, "Nothing is running")
        XCTAssertEqual(button("java.runTests", in: items)?.help, "Run Tests")
    }

    func testStopStaysWhileSomethingRunsEvenInAFileThatCannotRun() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "markdown"
        let session = IDERunSession(configurationID: UUID(), title: "Main", providerID: "java")
        workspace.runs.add(session)
        XCTAssertTrue(workspace.isRunActive)
        let stop = button("java.stop", in: workspace.toolbarItems())
        XCTAssertEqual(stop?.isEnabled, true)
        XCTAssertNotNil(stop?.tint)
        session.stop()
    }

    func testTheHTTPSendButtonNeedsARequestAtTheCaret() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "http"
        XCTAssertNil(button("http.send", in: workspace.toolbarItems()))
        workspace.httpFileCanSend = true
        XCTAssertEqual(button("http.send", in: workspace.toolbarItems())?.help, "Send HTTP Request")
        workspace.statusLanguage = "java"
        XCTAssertNil(button("http.send", in: workspace.toolbarItems()))
    }

    func testItemsAreInTheirDeclaredOrderWhateverTheModulesOrder() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "markdown"
        workspace.isMarkdownPreviewVisible = true
        workspace.runFileCanRun = true
        let orders = workspace.toolbarItems().map(\.order)
        XCTAssertEqual(orders, orders.sorted())
    }

    // MARK: Status bar

    func testTheJDKPickerIsATrailingItemWhileAJavaFileIsOpen() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.bootstrap()
        workspace.newFile()
        XCTAssertFalse(workspace.showsWelcome)
        workspace.statusLanguage = "java"
        XCTAssertEqual(workspace.statusItems(.trailing).map(\.id), ["java.jdk"])
        XCTAssertTrue(workspace.statusItems(.leading).isEmpty)
        workspace.statusLanguage = "markdown"
        XCTAssertTrue(workspace.statusItems(.trailing).isEmpty)
    }

    func testNoHTTPStatusItemUnlessARequestIsInFlight() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "http"
        XCTAssertTrue(workspace.statusItems(.leading).isEmpty)
    }

    // MARK: View menu

    func testRunMarkdownWithAgentIsAlwaysInTheViewMenuAndThePreviewOnlyForItsLanguages() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "java"
        XCTAssertEqual(workspace.viewMenuContributions().map(\.id), ["markdown.runWithAgent"])
        workspace.statusLanguage = "markdown"
        XCTAssertEqual(workspace.viewMenuContributions().map(\.id), ["markdown.runWithAgent", "markdown.preview"])
        workspace.statusLanguage = "json"
        XCTAssertEqual(workspace.viewMenuContributions().map(\.id), ["markdown.runWithAgent", "json.diagram"])
        workspace.statusLanguage = "tsv"
        XCTAssertEqual(workspace.viewMenuContributions().map(\.id), ["markdown.runWithAgent", "csv.table"])
    }

    // MARK: Bottom tabs

    func testSelectingATabIsOneCallForEveryTab() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        XCTAssertFalse(workspace.isTerminalVisible)
        workspace.showBottomTab(.problems)
        XCTAssertTrue(workspace.isTerminalVisible, "Showing a tab reveals the panel")
        XCTAssertTrue(workspace.isBottomTabSelected(.problems))
        XCTAssertFalse(workspace.isBottomTabSelected(.usages))

        workspace.deselectBottomTab(.usages)
        XCTAssertTrue(workspace.isBottomTabSelected(.problems), "Closing another tab leaves this one")
        workspace.deselectBottomTab(.problems)
        XCTAssertTrue(workspace.isTerminalTabSelected, "The shell takes over")
    }

    func testChoosingAShellLeavesAnyReadOnlyTab() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.showBottomTab(.problems)
        workspace.addTerminalTab(saveSession: false)
        XCTAssertTrue(workspace.isTerminalTabSelected)

        workspace.showBottomTab(.usages)
        let first = workspace.terminalTabs[0].id
        workspace.selectTerminalTab(first)
        XCTAssertTrue(workspace.isTerminalTabSelected)
    }

    func testTheRunGradleAndHTTPTabsBringTheirOwnHeaderControls() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "http"
        workspace.runs.add(IDERunSession(configurationID: UUID(), title: "Main", providerID: "java"))
        let tabs = workspace.languageModuleBottomTabs()
        XCTAssertNotNil(tabs.first { $0.tab == .run }?.controls)
        XCTAssertNotNil(tabs.first { $0.tab == .http }?.controls)
        XCTAssertEqual(tabs.first { $0.tab == .run }?.staysWhenLastShellCloses, false)
    }

    // MARK: A module the app was not built with

    @MainActor
    private final class RubyRunProvider: IDERunProvider {
        let id = "ruby"
        let languageIdentifiers: Set<String> = ["ruby"]
        var hasActiveWork: Bool { false }
        func canRun(_ document: IDERunDocument) -> Bool { true }
        func canDebug(fileURL: URL?) -> Bool { false }
        func runHelp(fileURL: URL?) -> String { "Run ruby" }
        func debugHelp(fileURL: URL?, canRun: Bool) -> String { "No debugger" }
        func run(_ document: IDERunDocument, mode: IDERunMode) {}
        func runInContext(_ document: IDERunDocument, mode: IDERunMode) async -> Bool { false }
        func rerun(_ session: IDERunSession) {}
        func stop() {}
    }

    private struct FakeRubyModule: IDELanguageModule {
        static let id = "ruby"
        var id: String { Self.id }
        static let tab = IDEBottomPanelTab("ruby")
        static let sidebar = IDESidebarTab(rawValue: "ruby")
        static let page = IDEPreferencesDomain(id: "ruby", title: "Ruby", symbol: "diamond", searchTerms: ["gem", "bundler"])

        func commands(for workspace: IDEWorkspace) -> [EditorCommand] {
            [EditorCommand(id: "app.ruby.irb", title: "Ruby: Open IRB", group: "Ruby", action: {})]
        }

        func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] {
            [IDEToolWindow(
                id: "ruby", systemImage: "diamond", title: "Ruby", shortcut: nil, tint: .red, placement: .trailingTop,
                isOpen: false, toggle: {}, order: 450
            )]
        }

        func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution] {
            [IDEBottomTabContribution(
                tab: Self.tab, order: 15, item: { _ in AnyView(Text("Ruby")) }, content: { _ in AnyView(EmptyView()) },
                controls: { _ in AnyView(Text("controls")) }, staysWhenLastShellCloses: true
            )]
        }

        var sidebarTabs: [IDESidebarTabDescriptor] {
            [IDESidebarTabDescriptor(
                tab: Self.sidebar, title: "Gems", systemImage: "diamond", order: 35, content: { _ in AnyView(EmptyView()) }
            )]
        }

        func menu(for workspace: IDEWorkspace) -> IDEModuleMenu? {
            workspace.statusLanguage == "ruby" ? IDEModuleMenu(title: "Ruby") { _ in AnyView(EmptyView()) } : nil
        }

        var preferencePanes: [IDEPreferencesPane] {
            [IDEPreferencesPane(domain: Self.page) { _, _ in AnyView(EmptyView()) }]
        }

        func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
            guard workspace.statusLanguage == "ruby" else { return [] }
            return [.button(id: "ruby.irb", order: 260, systemImage: "terminal", help: "Open IRB", action: {})]
        }

        func statusItems(for workspace: IDEWorkspace) -> [IDEStatusItem] {
            guard workspace.statusLanguage == "ruby" else { return [] }
            return [IDEStatusItem(id: "ruby.version", placement: .trailing, order: 50, content: AnyView(Text("ruby 3.4")))]
        }

        func viewMenuItems(for workspace: IDEWorkspace) -> [IDEViewMenuContribution] {
            [IDEViewMenuContribution(id: "ruby.rdoc") { _ in AnyView(EmptyView()) }]
        }

        func makeRunProvider(for workspace: IDEWorkspace) -> (any IDERunProvider)? {
            RubyRunProvider()
        }
    }

    func testARegisteredModuleReachesEveryContributionPoint() {
        IDELanguageModules.register(FakeRubyModule())
        XCTAssertEqual(IDELanguageModules.all.map(\.id).last, "ruby", "A new module goes after the shipped ones")

        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "ruby"

        // Palette.
        let controller = CommandPaletteController(textView: makeFocusedTextView(text: "x"))
        workspace.configurePalette(controller)
        XCTAssertEqual(controller.commandRegistry.commands.filter { $0.id == "app.ruby.irb" }.count, 1)
        // Tool window stripe and bottom panel.
        XCTAssertTrue(workspace.toolWindows.contains { $0.id == "ruby" })
        let contribution = workspace.languageModuleBottomTabs().first { $0.tab == FakeRubyModule.tab }
        XCTAssertNotNil(contribution)
        XCTAssertNotNil(contribution?.controls)
        workspace.showBottomTab(FakeRubyModule.tab)
        XCTAssertTrue(workspace.isBottomTabSelected(FakeRubyModule.tab))
        XCTAssertTrue(workspace.isBottomToolWindowOpen(FakeRubyModule.tab))
        // Closing the last shell keeps the panel on a tab that asked to stay.
        workspace.addTerminalTab(saveSession: false)
        XCTAssertTrue(workspace.isTerminalTabSelected)
        workspace.closeTerminalTab(workspace.terminalTabs[0].id)
        XCTAssertTrue(workspace.isBottomTabSelected(FakeRubyModule.tab))
        XCTAssertTrue(workspace.isTerminalVisible)
        // Left sidebar.
        XCTAssertEqual(IDESidebarTabs.descriptor(for: FakeRubyModule.sidebar)?.title, "Gems")
        XCTAssertTrue(workspace.isSidebarTabAvailable(FakeRubyModule.sidebar))
        XCTAssertEqual(IDESidebarTabs.all.map(\.order), IDESidebarTabs.all.map(\.order).sorted())
        // Settings.
        XCTAssertTrue(IDELanguageModules.preferencePanes.contains { $0.domain == FakeRubyModule.page })
        XCTAssertTrue(IDEPreferencesDomain.ordered(with: IDELanguageModules.preferencePanes.map(\.domain)).contains(FakeRubyModule.page))
        XCTAssertTrue(FakeRubyModule.page.matches("bundler"))
        // Menu bar.
        XCTAssertEqual(workspace.languageModuleMenu(for: "ruby")?.title, "Ruby")
        // Toolbar, status bar, View menu.
        XCTAssertEqual(ids(workspace.toolbarItems()), ["java.runConfigurations", "ruby.irb"])
        XCTAssertEqual(workspace.statusItems(.trailing).map(\.id), ["ruby.version"])
        XCTAssertTrue(workspace.viewMenuContributions().contains { $0.id == "ruby.rdoc" })
        // Run.
        XCTAssertTrue(workspace.runProviders.provider(forLanguage: "ruby") is RubyRunProvider)
        XCTAssertNil(workspace.runProviders.provider(forLanguage: "swift"))
    }

    func testAnUnregisteredModuleLeavesNothingBehind() {
        IDELanguageModules.register(FakeRubyModule())
        IDELanguageModules.unregister(id: FakeRubyModule.id)

        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.statusLanguage = "ruby"
        XCTAssertEqual(IDELanguageModules.all.map(\.id), ["java", "http", "markdown", "json", "csv", "typescript"])
        XCTAssertNil(IDESidebarTabs.descriptor(for: FakeRubyModule.sidebar))
        XCTAssertFalse(workspace.languageModuleBottomTabs().contains { $0.tab == FakeRubyModule.tab })
        XCTAssertEqual(ids(workspace.toolbarItems()), ["java.runConfigurations"])
        XCTAssertNil(workspace.runProviders.provider(forLanguage: "ruby"))
        XCTAssertNil(workspace.languageModuleMenu(for: "ruby"))
    }

    func testRegisteringAnIdTwiceReplacesTheEarlierModule() {
        IDELanguageModules.register(FakeRubyModule())
        IDELanguageModules.register(FakeRubyModule())
        XCTAssertEqual(IDELanguageModules.all.filter { $0.id == "ruby" }.count, 1)
    }
}
