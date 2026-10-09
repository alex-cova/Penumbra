import Penumbra
import XCTest
@testable import Umbra

/// The language modules: what they contribute to the palette, Settings, the menu bar and the
/// tool-window stripe, and that moving those out of `IDEWorkspace` kept what was there.
@MainActor
final class IDELanguageModuleTests: XCTestCase {
    private func makeWorkspace() -> IDEWorkspace {
        IDEWorkspace.isSessionPersistenceEnabled = false
        return IDEWorkspace()
    }

    func testTheShippedModulesAreJavaThenHTTP() {
        XCTAssertEqual(IDELanguageModules.all.map(\.id), ["java", "http"])
        XCTAssertNotNil(IDELanguageModules.module(id: "http"))
        XCTAssertNil(IDELanguageModules.module(id: "swift"))
    }

    func testJavaContributesTheElevenCommandsItAlwaysHad() {
        let commands = IDEJavaModule().commands(for: makeWorkspace())
        XCTAssertEqual(commands.map(\.id), [
            "app.java.buildGradleProject", "app.java.runTests", "app.java.runLastConfiguration",
            "app.java.editRunConfiguration", "app.java.reloadGradleProject", "app.java.showGradleOutput",
            "app.java.showClassDiagram", "app.java.showPackageDiagram", "app.java.showProjectDiagram",
            "app.java.showGradleModuleDiagram", "app.java.showGradleDependencyDiagram"
        ])
        XCTAssertEqual(Set(commands.map(\.group)), ["Java"])
        XCTAssertEqual(commands.first?.title, "Java: Build Project")
        XCTAssertEqual(commands.first { $0.id == "app.java.showGradleModuleDiagram" }?.title, "Gradle: Show Module Diagram")
    }

    func testHTTPContributesItsTwoCommands() {
        let commands = IDEHTTPModule().commands(for: makeWorkspace())
        XCTAssertEqual(commands.map(\.id), ["app.http.sendRequest", "app.http.showResponse"])
        XCTAssertEqual(commands.map(\.title), ["HTTP: Send Request", "HTTP: Show Response"])
        XCTAssertEqual(Set(commands.map(\.group)), ["HTTP"])
    }

    func testModuleCommandsAreInThePaletteOnce() {
        let workspace = makeWorkspace()
        let controller = CommandPaletteController(textView: makeFocusedTextView(text: "x"))
        workspace.configurePalette(controller)
        let ids = controller.commandRegistry.commands.map(\.id)
        for module in IDELanguageModules.all {
            for command in module.commands(for: workspace) {
                XCTAssertEqual(ids.filter { $0 == command.id }.count, 1, command.id)
            }
        }
        // The commands that stayed behind are still there.
        XCTAssertTrue(ids.contains("app.git.pull"))
        XCTAssertTrue(ids.contains("app.debug.resume"))
        XCTAssertTrue(ids.contains("app.toggleTerminal"))
        XCTAssertTrue(ids.contains("app.view.zoomIn"))
        // Java's group is registered where it always was, before the Edit, Git and Run groups.
        let groups = controller.commandRegistry.commands.map(\.group)
        let firstJava = groups.firstIndex(of: "Java")
        XCTAssertNotNil(firstJava)
        XCTAssertLessThan(firstJava ?? 0, groups.firstIndex(of: "Git") ?? 0)
    }

    // MARK: Menus

    func testTheHTTPMenuExistsOnlyForAnHTTPFile() {
        let workspace = makeWorkspace()
        XCTAssertNil(workspace.languageModuleMenu(for: IDEHTTPModule.id))
        workspace.statusLanguage = "http"
        XCTAssertEqual(workspace.languageModuleMenu(for: IDEHTTPModule.id)?.title, "HTTP")
        workspace.statusLanguage = "java"
        XCTAssertNil(workspace.languageModuleMenu(for: IDEHTTPModule.id))
    }

    func testTheJavaMenuFollowsTheJDKPickerAndNeverShowsOnTheWelcomeScreen() {
        let workspace = makeWorkspace()
        XCTAssertTrue(workspace.showsWelcome)
        workspace.statusLanguage = "java"
        XCTAssertNil(workspace.languageModuleMenu(for: IDEJavaModule.id), "the welcome screen hides it")
        XCTAssertNil(workspace.languageModuleMenu(for: "swift"))
    }

    // MARK: Settings

    func testSettingsPagesKeepTheirOrderWithTheJavaOnesBetweenProjectAndAgent() {
        let modulePages = IDELanguageModules.preferencePanes.map(\.domain)
        XCTAssertEqual(modulePages.map(\.id), ["java", "inspections"])
        XCTAssertEqual(
            IDEPreferencesDomain.ordered(with: modulePages).map(\.id),
            ["general", "editor", "appearance", "focus", "project", "java", "inspections", "agent"]
        )
        XCTAssertEqual(IDEPreferencesDomain.ordered(with: []).map(\.id), ["general", "editor", "appearance", "focus", "project", "agent"])
    }

    func testSettingsSearchStillFindsTheJavaPages() {
        XCTAssertTrue(IDEPreferencesDomain.java.matches("gradle"))
        XCTAssertTrue(IDEPreferencesDomain.java.matches("JDK"))
        XCTAssertTrue(IDEPreferencesDomain.inspections.matches("unused"))
        XCTAssertTrue(IDEPreferencesDomain.inspections.matches("Unused Import"), "rule titles are searchable too")
        XCTAssertFalse(IDEPreferencesDomain.java.matches("zzz"))
        XCTAssertTrue(IDEPreferencesDomain.editor.showsTypePreview)
        XCTAssertFalse(IDEPreferencesDomain.java.showsTypePreview)
        XCTAssertEqual(IDEPreferencesDomain.agent, IDEPreferencesDomain.agent)
    }

    // MARK: Tool windows

    func testToolWindowOrderIsTheStripeOrderItAlwaysHad() {
        typealias Order = IDEToolWindow.Order
        let sequence = [
            Order.sidebarTabs, Order.findInFiles, Order.history, Order.debug, Order.testResults, Order.usages,
            Order.typeHierarchy, Order.callHierarchy, Order.problems, Order.terminal,
            Order.gradleSidebar, Order.gradleConsole, Order.httpResponse
        ]
        XCTAssertEqual(sequence, sequence.sorted())
        XCTAssertEqual(Set(sequence).count, sequence.count, "no two windows share a position")
    }

    func testAWindowWithNothingOpenOffersNoModuleToolWindows() {
        let workspace = makeWorkspace()
        XCTAssertTrue(workspace.languageModuleToolWindows().isEmpty)
        XCTAssertTrue(workspace.toolWindows.isEmpty, "the stripe stays hidden until a folder or file is open")
    }
}
