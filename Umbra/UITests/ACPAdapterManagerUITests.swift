import XCTest

/// GUI regression for the ACP Adapter Manager.
///
/// Ordinary tests use `--acp-ui-test`: a temporary adapter directory, a fake registry, and a fake
/// npm that never touches the network, the global npm prefix, or the user's managed adapters.
/// The handshake is a real Node process speaking ACP. `ACPAdapterLiveUITests` is the opt-in path
/// for an already installed agent and does not run unless `UMBRA_LIVE_ACP_UI=1`.
///
/// VoiceOver behaviors XCUITest cannot observe, and that still need a manual pass with VoiceOver on:
/// - Rotor navigation (headings, buttons, links) through Settings and the agent transcript.
/// - The order in which announcements are spoken when several banners appear together.
/// - Whether an install error or an offline banner is spoken without moving keyboard focus.
/// - Whether install progress is spoken as it changes. The tests only check the accessibility value.
/// - Whether the keyboard focus ring is visible. The tests check where keystrokes land.
@MainActor
final class ACPAdapterManagerUITests: XCTestCase {
    func testSettingsWindowLifecycle() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        ui.launch(scenario: "empty")
        let gear = ui.wait(ACPUIID.settingsOpen, timeout: 45)
        let mainWindow = ui.app.windows.firstMatch
        gear.click()
        let settings = ui.app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(ui.wait(ACPUIID.settingsSearch).exists)
        ui.app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(ui.app.windows.matching(identifier: "Settings").count, 1)
        ui.app.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        XCTAssertTrue(mainWindow.exists)
        ui.app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(mainWindow.exists)
    }

    func testSettingsNavigation() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        ui.launch(scenario: "empty")
        ui.showAdapters()
        XCTAssertTrue(ui.element(ACPUIID.settingsDomain("agent")).exists)
        XCTAssertTrue(ui.element(ACPUIID.adapter(ACPUIID.codex)).waitForExistence(timeout: 15))
        XCTAssertTrue(ui.element(ACPUIID.adapter(ACPUIID.claude)).exists)
        let check = ui.reveal(ACPUIID.checkUpdates)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: check)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        check.click()
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: check)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        XCTAssertTrue(ui.element(ACPUIID.adapter(ACPUIID.codex)).exists)
        XCTAssertTrue(ui.element(ACPUIID.adapter(ACPUIID.claude)).exists)
        ui.reveal(ACPUIID.install(ACPUIID.codex))
        XCTAssertTrue(ui.element(ACPUIID.install(ACPUIID.codex)).isHittable)
    }

    func testAdapterDiscovery() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        ui.launch(scenario: "empty")
        ui.showAdapters()
        ui.reveal(ACPUIID.status(ACPUIID.codex))
        ui.expectText(ui.element(ACPUIID.status(ACPUIID.codex)), "Not installed.", timeout: 10)
        XCTAssertTrue(ui.text(containing: "@agentclientprotocol/codex-acp").waitForExistence(timeout: 5))
        XCTAssertTrue(ui.text(containing: "@agentclientprotocol/claude-agent-acp").exists)
        XCTAssertTrue(ui.text(containing: "Gemini CLI").exists)
        XCTAssertTrue(ui.text(containing: "OpenCode").exists)
        XCTAssertTrue(ui.element(ACPUIID.updatePolicy).exists)
        XCTAssertEqual(ui.element(ACPUIID.checkUpdates).label, "Check for adapter updates now")
    }

    func testInstallationConfirmation() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "empty")
        ui.showAdapters()
        ui.beginInstall(ACPUIID.codex)
        let package = ui.element(ACPUIID.approvalPackage)
        XCTAssertTrue(package.waitForExistence(timeout: 5))
        ui.expectText(package, "@agentclientprotocol/codex-acp@2.6.0", timeout: 5)
        XCTAssertTrue(ui.text(containing: "registry.npmjs.org").exists)
        XCTAssertFalse(ui.element(ACPUIID.approvalCancel).label.isEmpty)
        XCTAssertFalse(ui.element(ACPUIID.approvalConfirm).label.isEmpty)
        ui.app.typeKey(.escape, modifierFlags: [])
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: ui.element(ACPUIID.approval))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "Escape did not cancel the sheet")
        ui.expectText(ui.element(ACPUIID.status(ACPUIID.codex)), "Not installed.", timeout: 5)
    }

    func testInstallationProgress() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "slow", extra: ["UMBRA_ACP_UI_DELAY_MS": "12000"])
        ui.showAdapters()
        ui.beginInstall(ACPUIID.codex)
        ui.confirmApproval()
        let progress = ui.element(ACPUIID.progress(ACPUIID.codex))
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        XCTAssertFalse(progress.label.isEmpty, "progress has no accessibility label")
        XCTAssertNotNil(progress.value as? NSNumber, "progress has no numeric accessibility value")
        ui.expectText(ui.element(ACPUIID.status(ACPUIID.codex)), "Ready", timeout: 40)
        XCTAssertTrue(ui.text(containing: "Installed: 2.6.0").waitForExistence(timeout: 5))
    }

    func testInstallationCancellation() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "hang")
        ui.showAdapters()
        ui.beginInstall(ACPUIID.codex)
        ui.confirmApproval()
        let cancel = ui.reveal(ACPUIID.cancel(ACPUIID.codex))
        XCTAssertTrue(cancel.isHittable)
        cancel.click()
        ui.expectText(ui.element(ACPUIID.status(ACPUIID.codex)), "Not installed.", timeout: 20)
        XCTAssertFalse(ui.element(ACPUIID.cancel(ACPUIID.codex)).exists)
    }

    func testInstallationFailure() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "fail")
        ui.showAdapters()
        ui.beginInstall(ACPUIID.codex)
        ui.confirmApproval()
        let failure = ui.element(ACPUIID.status(ACPUIID.codex)).descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS %@", "fixture npm failure")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 20))
        XCTAssertTrue(ui.text(containing: "Failed").waitForExistence(timeout: 5))
        XCTAssertTrue(ui.element(ACPUIID.retry(ACPUIID.codex)).exists)
    }

    func testConnectionTesting() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "installed")
        ui.showAdapters()
        ui.reveal(ACPUIID.test(ACPUIID.codex)).click()
        ui.expectText(ui.element(ACPUIID.connection(ACPUIID.codex)), "OK", timeout: 30)
    }

    func testAgentProviderSelection() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        ui.launch(scenario: "installed")
        ui.showAgent()
        ui.chooseProvider(containing: "Codex")
        ui.chooseProvider(containing: "Claude Code")
        ui.chooseProvider(containing: "Umbra Native")
    }

    func testStreamingMessages() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "installed")
        ui.showAgent()
        ui.chooseProvider(containing: "Codex")
        ui.sendMessage("hello")
        XCTAssertTrue(ui.text(containing: "the fixture").waitForExistence(timeout: 30))
    }

    func testToolExecution() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "installed")
        ui.showAgent()
        ui.chooseProvider(containing: "Codex")
        ui.sendMessage("umbra-fixture:tool")
        let card = ui.wait(ACPUIID.tool("tool-1"), timeout: 30)
        XCTAssertTrue(card.label.contains("fixture-read") || ui.text(containing: "fixture-read").waitForExistence(timeout: 5))
    }

    func testPermissionApprovalAndRejection() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "installed")
        ui.showAgent()
        ui.chooseProvider(containing: "Codex")

        ui.sendMessage("umbra-fixture:permit")
        ui.wait(ACPUIID.approvalAllow, timeout: 30).click()
        XCTAssertTrue(ui.text(containing: "perm:allow-once").waitForExistence(timeout: 15))

        ui.sendMessage("umbra-fixture:reject")
        let deny = ui.wait(ACPUIID.approvalDeny, timeout: 30)
        XCTAssertTrue(deny.label.contains("Deny"))
        deny.click()
        let sendDenial = ui.element(ACPUIID.approvalDeny)
        ui.expect(sendDenial, "label CONTAINS %@", "Send Denial", timeout: 5)
        sendDenial.click()
        XCTAssertTrue(ui.text(containing: "perm:reject-once").waitForExistence(timeout: 15))
    }

    func testDiffReview() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "installed")
        ui.showAgent()
        ui.chooseProvider(containing: "Codex")
        ui.sendMessage("umbra-fixture:edit")
        XCTAssertTrue(ui.text(containing: "wrote note.txt").waitForExistence(timeout: 30))
        let change = ui.wait(ACPUIID.change("note.txt"), timeout: 15)
        XCTAssertEqual(change.label, "Show changes in note.txt")
        change.click()
        let diff = ui.wait(ACPUIID.diff, timeout: 10)
        XCTAssertTrue(diff.label.contains("note.txt (agent)"), diff.label)
    }

    func testUpdateRollbackAndVersionRemoval() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "update")
        ui.showAdapters()
        let update = ui.reveal(ACPUIID.update(ACPUIID.codex))
        XCTAssertTrue(update.waitForExistence(timeout: 20))
        ui.expectText(ui.element(ACPUIID.status(ACPUIID.codex)), "Update 2.6.0 is available.", timeout: 10)
        update.click()
        let package = ui.wait(ACPUIID.approvalPackage)
        ui.expectText(package, "2.6.0", timeout: 5)
        ui.expectText(package, "2.5.0", timeout: 5)
        ui.confirmApproval()
        ui.expectText(ui.element(ACPUIID.status(ACPUIID.codex)), "Ready", timeout: 40)
        XCTAssertTrue(ui.text(containing: "Installed: 2.6.0").waitForExistence(timeout: 5))

        ui.reveal(ACPUIID.more(ACPUIID.codex)).click()
        ui.clickMenu("Restore Previous Version")
        XCTAssertTrue(ui.text(containing: "Installed: 2.5.0").waitForExistence(timeout: 15))

        ui.reveal(ACPUIID.more(ACPUIID.codex)).click()
        ui.clickMenu("Version Details")
        ui.wait(ACPUIID.versions(ACPUIID.codex))
        ui.reveal(ACPUIID.removeVersion(ACPUIID.codex, "2.6.0")).click()
        XCTAssertTrue(ui.app.dialogs.staticTexts["Remove version 2.6.0?"].waitForExistence(timeout: 5))
        ui.clickAlert("Remove")
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: ui.element(ACPUIID.removeVersion(ACPUIID.codex, "2.6.0")))
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertTrue(ui.text(containing: "Installed: 2.5.0").exists)
    }

    func testRemovalBlockedWhileAChatIsRunning() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "installed")
        ui.showAgent()
        ui.chooseProvider(containing: "Codex")
        ui.sendMessage("umbra-fixture:linger")
        XCTAssertTrue(ui.text(containing: "partial").waitForExistence(timeout: 30))
        XCTAssertTrue(ui.element(ACPUIID.stop).waitForExistence(timeout: 5))

        ui.showAdapters()
        ui.reveal(ACPUIID.more(ACPUIID.codex)).click()
        ui.clickMenu("Remove Adapter…")
        XCTAssertTrue(ui.app.dialogs.staticTexts["Codex is in use"].waitForExistence(timeout: 5))
        ui.clickAlert("OK")
        XCTAssertTrue(ui.text(containing: "Installed: 2.6.0").exists)

        ui.wait(ACPUIID.stop).click()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: ui.element(ACPUIID.stop))
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 15), .completed)

        ui.reveal(ACPUIID.more(ACPUIID.codex)).click()
        ui.clickMenu("Remove Adapter…")
        XCTAssertTrue(ui.app.dialogs.staticTexts["Remove the Codex adapter?"].waitForExistence(timeout: 8))
        ui.clickAlert("Remove")
        ui.expectText(ui.element(ACPUIID.status(ACPUIID.codex)), "Not installed.", timeout: 15)
    }

    func testOfflineState() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        ui.launch(scenario: "offline")
        ui.showAdapters()
        let banner = ui.reveal(ACPUIID.adaptersOffline)
        ui.expectText(banner, "offline", timeout: 5)
        XCTAssertTrue(ui.text(containing: "Available: unknown (offline)").waitForExistence(timeout: 15))
        XCTAssertFalse(ui.element(ACPUIID.install(ACPUIID.codex)).label.isEmpty)
    }

    func testMissingNode() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        ui.launch(scenario: "nodeMissing")
        ui.showAdapters()
        let banner = ui.reveal(ACPUIID.adaptersNode)
        ui.expectText(banner, "Node.js", timeout: 5)
        XCTAssertTrue(ui.element(ACPUIID.install(ACPUIID.codex)).exists)
        XCTAssertTrue(ui.element(ACPUIID.install(ACPUIID.codex)).isEnabled)
    }

    func testKeyboardNavigationAndFocus() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        ui.launch(scenario: "empty")
        ui.wait(ACPUIID.settingsOpen, timeout: 45)
        ui.app.typeKey(",", modifierFlags: .command)
        let search = ui.wait(ACPUIID.settingsSearch)
        search.typeText("Agent")
        ui.expect(search, "value == %@", "Agent", timeout: 3)
        ui.app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(ui.element(ACPUIID.adapter(ACPUIID.codex)).waitForExistence(timeout: 15))

        ui.app.typeKey(.escape, modifierFlags: [])
        ui.expect(search, "value == %@", "", timeout: 3)
        ui.app.typeKey(.escape, modifierFlags: [])
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, "Escape did not close Settings")
    }

    func testApprovalSheetKeyboard() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        try ui.requireNode()
        ui.launch(scenario: "empty")
        ui.showAdapters()
        ui.beginInstall(ACPUIID.codex)
        ui.app.typeKey(.escape, modifierFlags: [])
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: ui.element(ACPUIID.approval))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        ui.expectText(ui.element(ACPUIID.status(ACPUIID.codex)), "Not installed.", timeout: 5)

        ui.beginInstall(ACPUIID.codex)
        ui.confirmApproval(with: .return)
        ui.expectText(ui.element(ACPUIID.status(ACPUIID.codex)), "Ready", timeout: 40)
    }

    func testAccessibilityLabels() throws {
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        ui.launch(scenario: "empty")
        ui.showAdapters()
        let labeled = [
            ACPUIID.settingsSearch,
            ACPUIID.settingsDomain("agent"),
            ACPUIID.updatePolicy,
            ACPUIID.checkUpdates,
            ACPUIID.install(ACPUIID.codex),
            ACPUIID.more(ACPUIID.codex),
        ]
        for identifier in labeled {
            let control = ui.reveal(identifier)
            XCTAssertFalse(
                control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(identifier) has no accessibility label")
        }
        let status = ui.reveal(ACPUIID.status(ACPUIID.codex))
        XCTAssertFalse(String(describing: status.value ?? "").isEmpty, "status has no accessibility value")
        let row = ui.element(ACPUIID.adapter(ACPUIID.codex))
        for index in 0..<row.images.count {
            let image = row.images.element(boundBy: index)
            guard image.exists else { continue }
            XCTAssertFalse(image.label.isEmpty, "an unlabeled image is exposed in the Codex row")
        }
    }
}
