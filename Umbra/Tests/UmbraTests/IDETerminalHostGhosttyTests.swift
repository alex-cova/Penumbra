import XCTest
@testable import Umbra

/// Host-level integration tests for the Ghostty backend (plan Step 5):
/// `IDETerminalHostView` creation, shell lifecycle, mirror feed,
/// title/directory/exit callbacks.
@MainActor
final class IDETerminalHostGhosttyTests: XCTestCase {
    private func makeHost(size: CGSize = CGSize(width: 800, height: 480)) -> IDETerminalHostView {
        let host = IDETerminalHostView(frame: NSRect(origin: .zero, size: size))
        host.layoutSubtreeIfNeeded()
        return host
    }

    @discardableResult
    private func waitFor(_ description: String, timeout: TimeInterval = 20, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func installShellFixture() {
        let preferences = IDEPreferences.shared
        let original = preferences.terminalShell
        var fixture = IDETerminalShellSettings()
        fixture.command = "/bin/sh"
        fixture.arguments = #"-c 'printf "umbra-terminal-ready:%s\n" "${PWD##*/}"; exec /bin/sleep 60'"#
        fixture.loginShell = false
        preferences.terminalShell = fixture
        addTeardownBlock { @MainActor in preferences.terminalShell = original }
    }

    func testShellStartsAndRendersOutput() {
        installShellFixture()
        let host = makeHost()
        defer { host.terminateProcess() }
        host.setActive(true)
        XCTAssertTrue(
            waitFor("shell output") { host.recentText(lines: 5)?.contains("umbra-terminal-ready:") == true },
            "the shell's output must reach the terminal")
    }

    func testMirrorTitleAndDirectoryCallbacks() {
        let host = makeHost()
        var titles: [String] = []
        var directories: [URL] = []
        host.onTitleUpdate = { titles.append($0) }
        host.onDirectoryUpdate = { directories.append($0) }
        host.setMirrorsOutput(true)
        host.setActive(true)
        host.feedOutput("\u{1B}]0;ghostty-title-test\u{07}\u{1B}]7;file:///tmp\u{07}")
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(waitFor("title") { titles == ["ghostty-title-test"] })
        XCTAssertTrue(waitFor("directory") { directories == [URL(fileURLWithPath: "/tmp")] })
    }

    func testMirrorFeedSurfacesText() {
        let host = makeHost()
        host.setMirrorsOutput(true)
        host.setActive(true)
        host.feedOutput("mirror-line-1\r\n")
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            waitFor("mirror") { host.recentText(lines: 5)?.contains("mirror-line-1") == true },
            "mirror feed must appear in recentText")
    }

    func testRestartRecoversShell() {
        installShellFixture()
        let host = makeHost()
        defer { host.terminateProcess() }
        host.workingDirectory = URL(fileURLWithPath: "/usr", isDirectory: true)
        host.setActive(true)
        XCTAssertTrue(waitFor("first shell") { host.recentText(lines: 5)?.contains("umbra-terminal-ready:usr") == true })
        host.workingDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)
        host.restartProcess()
        XCTAssertTrue(waitFor("restarted shell") { host.recentText(lines: 5)?.contains("umbra-terminal-ready:Applications") == true })
    }
}
