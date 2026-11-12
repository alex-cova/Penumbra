import XCTest

/// Opt-in look at a real adapter directory. Ordinary regression does not run this.
///
/// Set `UMBRA_LIVE_ACP_UI=1` in the test runner. The app still uses an isolated session and
/// defaults suite. The adapter root is the temporary directory this test creates, unless the
/// runner also sets `UMBRA_ACP_UI_ROOT`. Pointing that at
/// `~/Library/Application Support/com.umbra.editor/ACP` reads the real installs. Loading that
/// directory runs recovery, which deletes an interrupted staging folder. This test never clicks
/// Install, Update, or Remove, and the launch forces the update check to Manual so it does not
/// contact the registry by itself.
@MainActor
final class ACPAdapterLiveUITests: XCTestCase {
    func testReadsInstalledAdaptersWithoutChangingThem() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UMBRA_LIVE_ACP_UI"] == "1",
            "Set UMBRA_LIVE_ACP_UI=1 to open the real adapter UI. This is not part of ordinary regression.")
        let ui = try ACPUIHarness()
        defer { ui.cleanup() }
        var extra: [String: String] = [:]
        if let root = ProcessInfo.processInfo.environment["UMBRA_ACP_UI_ROOT"], !root.isEmpty {
            extra["UMBRA_ACP_UI_ROOT"] = root
        }
        ui.launch(scenario: "empty", extra: extra, live: true)
        ui.showAdapters()
        XCTAssertTrue(ui.element(ACPUIID.adapter(ACPUIID.codex)).waitForExistence(timeout: 20))
        XCTAssertTrue(ui.element(ACPUIID.adapter(ACPUIID.claude)).exists)
        XCTAssertFalse(ui.element(ACPUIID.approval).exists, "the live test must not present an install sheet")
    }
}
