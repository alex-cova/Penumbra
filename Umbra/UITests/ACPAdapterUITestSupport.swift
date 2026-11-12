import XCTest

/// Identifiers duplicated from `IDEACPAccessibility`. UI tests do not link the app, so the strings
/// live here as well. A rename has to change both.
enum ACPUIID {
    static let settingsSearch = "settings.search"
    static let settingsSidebar = "settings.sidebar"
    static let settingsDetail = "settings.detail"
    static let settingsOpen = "settings.open"
    static let agentToggle = "agent.toggle"
    static func settingsDomain(_ id: String) -> String { "settings.domain.\(id)" }

    static let adapters = "acp.adapters"
    static let adaptersOffline = "acp.adapters.offline"
    static let adaptersNode = "acp.adapters.node"
    static let updatePolicy = "acp.adapters.updatePolicy"
    static let checkUpdates = "acp.adapters.checkUpdates"

    static func adapter(_ id: String) -> String { "acp.adapter.\(id)" }
    static func install(_ id: String) -> String { "acp.adapter.\(id).install" }
    static func update(_ id: String) -> String { "acp.adapter.\(id).update" }
    static func cancel(_ id: String) -> String { "acp.adapter.\(id).cancel" }
    static func retry(_ id: String) -> String { "acp.adapter.\(id).retry" }
    static func test(_ id: String) -> String { "acp.adapter.\(id).test" }
    static func more(_ id: String) -> String { "acp.adapter.\(id).more" }
    static func status(_ id: String) -> String { "acp.adapter.\(id).status" }
    static func progress(_ id: String) -> String { "acp.adapter.\(id).progress" }
    static func message(_ id: String) -> String { "acp.adapter.\(id).message" }
    static func connection(_ id: String) -> String { "acp.adapter.\(id).connection" }
    static func versions(_ id: String) -> String { "acp.adapter.\(id).versions" }
    static func restore(_ id: String) -> String { "acp.adapter.\(id).restore" }
    static func remove(_ id: String) -> String { "acp.adapter.\(id).remove" }
    static func details(_ id: String) -> String { "acp.adapter.\(id).details" }
    static func removeVersion(_ id: String, _ version: String) -> String {
        "acp.adapter.\(id).version.\(version).remove"
    }

    static let approval = "acp.approval"
    static let approvalConfirm = "acp.approval.confirm"
    static let approvalCancel = "acp.approval.cancel"
    static let approvalPackage = "acp.approval.package"

    static let provider = "acp.provider"
    static let composer = "agent.composer"
    static let send = "agent.send"
    static let stop = "agent.stop"
    static func tool(_ id: String) -> String { "agent.tool.\(id)" }
    static let approvalAllow = "agent.approval.allow"
    static let approvalDeny = "agent.approval.deny"
    static let changes = "agent.changes"
    static func change(_ path: String) -> String { "agent.change.\(path)" }
    static let diff = "agent.diff"

    static let codex = "codex-acp"
    static let claude = "claude-agent-acp"
}

/// Captured registry documents the fixture fetcher serves. No test contacts registry.npmjs.org.
enum ACPUIFixtures {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/UmbraTests/Fixtures/ACPAdapters", isDirectory: true)
}

/// One Umbra launch against a temporary adapter root, session directory, and defaults suite.
///
/// The app is started with `--acp-ui-test`. That flag is compiled out of Release builds. The
/// launch environment is explicit so the app does not inherit `XCTestConfigurationFilePath`:
/// `IDEAlert` declines modals when it sees that variable, and these tests have to click them.
@MainActor
final class ACPUIHarness {
    let app = XCUIApplication()
    let root: URL
    let session: URL
    let workspace: URL
    let file: URL
    let suite: String
    private let base: URL

    init() throws {
        let id = UUID().uuidString
        base = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-ui-\(id)", isDirectory: true)
        root = base.appendingPathComponent("adapters", isDirectory: true)
        session = base.appendingPathComponent("session", isDirectory: true)
        workspace = base.appendingPathComponent("project", isDirectory: true)
        file = workspace.appendingPathComponent("readme.txt")
        suite = "com.umbra.editor.acp-ui-test.\(id)"
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ACPUIFixtures.directory.path), "missing \(ACPUIFixtures.directory.path)")
    }

    func cleanup() {
        if app.state != .notRunning { app.terminate() }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    /// Install, chat, and connection tests start a real Node process. Discovery does not.
    func requireNode() throws {
        let found = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        try XCTSkipUnless(found, "Node.js is not on this Mac. Handshake tests need /opt/homebrew/bin/node, /usr/local/bin/node, or /usr/bin/node.")
    }

    func launch(scenario: String, extra: [String: String] = [:], live: Bool = false) {
        var environment = Self.safeEnvironment
        environment["UMBRA_ACP_UI_ROOT"] = root.path
        environment["UMBRA_ACP_UI_SESSION"] = session.path
        environment["UMBRA_ACP_UI_DEFAULTS"] = suite
        environment["UMBRA_ACP_UI_FIXTURES"] = ACPUIFixtures.directory.path
        environment["UMBRA_ACP_UI_SCENARIO"] = scenario
        if live { environment["UMBRA_ACP_UI_LIVE"] = "1" }
        for (key, value) in extra { environment[key] = value }
        app.launchEnvironment = environment
        app.launchArguments = ["--acp-ui-test", "--open", file.path, "--open-folder", workspace.path]
        app.launch()
        // SwiftUI can restore a previously closed window group with no initial window. Open one
        // through the normal app command so the launch arguments still reach the first workspace.
        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.menuBars.menuBarItems["File"].click()
            let newWindow = app.menuItems["New Window"]
            XCTAssertTrue(newWindow.waitForExistence(timeout: 5))
            newWindow.click()
        }
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    @discardableResult
    func wait(_ identifier: String, timeout: TimeInterval = 20) -> XCUIElement {
        let found = element(identifier)
        XCTAssertTrue(found.waitForExistence(timeout: timeout), "missing \(identifier)")
        return found
    }

    /// Scrolls Settings until the control can be clicked. The Adapters section sits below the agent form.
    @discardableResult
    func reveal(_ identifier: String, timeout: TimeInterval = 15) -> XCUIElement {
        let target = wait(identifier, timeout: 20)
        let scroll = element(ACPUIID.settingsDetail)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, target.exists, !target.isHittable {
            if scroll.exists {
                scroll.scroll(byDeltaX: 0, deltaY: -450)
            } else {
                break
            }
        }
        return target
    }

    func showAdapters() {
        let gear = wait(ACPUIID.settingsOpen, timeout: 45)
        gear.click()
        let search = wait(ACPUIID.settingsSearch)
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Agent")
        app.typeKey(.return, modifierFlags: [])
        wait(ACPUIID.adapters, timeout: 20)
    }

    func showAgent() {
        let toggle = wait(ACPUIID.agentToggle, timeout: 45)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed, "Agent stayed disabled; the project folder did not open")
        toggle.click()
        wait(ACPUIID.provider)
    }

    func chooseProvider(containing name: String) {
        element(ACPUIID.provider).click()
        let item = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no provider menu item containing \(name)")
        item.click()
        expect(element(ACPUIID.provider), "value CONTAINS %@", name, timeout: 5)
    }

    func sendMessage(_ text: String) {
        let composer = wait(ACPUIID.composer)
        composer.click()
        composer.typeText(text)
        let send = wait(ACPUIID.send)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "Send stayed disabled")
        send.click()
    }

    func beginInstall(_ id: String) {
        reveal(ACPUIID.install(id)).click()
        let sheet = element(ACPUIID.approval)
        if !sheet.waitForExistence(timeout: 25) {
            let message = element(ACPUIID.message(id))
            XCTFail("approval sheet did not appear. \(message.exists ? message.label : "no error message")")
        }
    }

    func confirmApproval(with key: XCUIKeyboardKey? = nil) {
        if let key {
            app.typeKey(key, modifierFlags: [])
        } else {
            element(ACPUIID.approvalConfirm).click()
        }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(ACPUIID.approval))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "approval sheet stayed open")
    }

    func clickMenu(_ title: String) {
        let item = app.menuItems[title]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, "menu item \(title)")
        item.click()
    }

    func clickAlert(_ title: String) {
        let dialogButton = app.dialogs.buttons[title]
        if dialogButton.waitForExistence(timeout: 8) {
            dialogButton.click()
            return
        }
        let sheetButton = app.sheets.buttons[title]
        XCTAssertTrue(sheetButton.waitForExistence(timeout: 2), "no alert button \(title)")
        sheetButton.click()
    }

    func text(containing needle: String) -> XCUIElement {
        app.descendants(matching: .staticText).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", needle, needle)).firstMatch
    }

    /// Static text on macOS is exposed as a value; grouped status elements may expose a label.
    func expectText(_ element: XCUIElement, _ value: String, timeout: TimeInterval) {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "wanted \(value); label=\(element.label) value=\(String(describing: element.value))")
    }

    func expect(_ element: XCUIElement, _ format: String, _ value: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
            "wanted \(format) \(value); label=\(element.label) value=\(String(describing: element.value))")
    }

    /// HOME and PATH only. XCTest injection variables stay in the runner, not the app.
    private static var safeEnvironment: [String: String] {
        var copy: [String: String] = [:]
        let source = ProcessInfo.processInfo.environment
        for key in ["HOME", "TMPDIR", "PATH", "USER", "LOGNAME", "SHELL", "LANG"] {
            if let value = source[key] { copy[key] = value }
        }
        return copy
    }
}
