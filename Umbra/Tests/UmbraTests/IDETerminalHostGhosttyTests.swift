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

    func testShellStartsAndPromptAppears() {
        let host = makeHost()
        host.setActive(true)
        XCTAssertTrue(
            waitFor("prompt") { host.recentText(lines: 5)?.contains("%") == true },
            "ghostty-backed host must reach a shell prompt")
        host.terminateProcess()
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
        let host = makeHost()
        host.setActive(true)
        XCTAssertTrue(waitFor("prompt") { host.recentText(lines: 5)?.contains("%") == true })
        host.restartProcess()
        XCTAssertTrue(waitFor("prompt again") { host.recentText(lines: 5)?.contains("%") == true })
        host.terminateProcess()
    }
}
