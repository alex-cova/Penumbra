import AppKit
import XCTest
@testable import Umbra

/// A full-screen program in the terminal, end to end: `less` through a real PTY in an
/// `IDETerminalHostView`, driven by wheel events and a resize the way the panel delivers them.
@MainActor
final class IDETerminalInteractiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-interactive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func waitFor(timeout: TimeInterval = 20, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return check()
    }

    /// Runs `less` on a 300-line file, starting at its end, as the terminal's shell.
    private func startLess(size: CGSize) throws -> IDETerminalHostView {
        let file = directory.appendingPathComponent("numbers.txt")
        try (1...300).map { String(format: "row-%03d", $0) }.joined(separator: "\n")
            .appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let preferences = IDEPreferences.shared
        let original = preferences.terminalShell
        var fixture = IDETerminalShellSettings()
        fixture.command = "/usr/bin/less"
        fixture.arguments = "+G \(file.path)"
        fixture.loginShell = false
        fixture.environment = [IDETerminalEnvironmentVariable(name: "LESS", value: ""),
                               IDETerminalEnvironmentVariable(name: "LESSHISTFILE", value: "-")]
        preferences.terminalShell = fixture
        addTeardownBlock { @MainActor in preferences.terminalShell = original }

        let host = IDETerminalHostView(frame: NSRect(origin: .zero, size: size))
        host.layoutSubtreeIfNeeded()
        host.setActive(true)
        XCTAssertTrue(waitFor { host.visibleText()?.contains("row-300") == true }, "less shows the end of the file")
        return host
    }

    private func wheel(_ lines: Int32, on host: IDETerminalHostView) throws {
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        host.terminalView.scrollWheel(with: event)
    }

    /// The number of the first `row-NNN` line on screen.
    private func firstRow(_ host: IDETerminalHostView) -> Int? {
        guard let line = host.visibleText()?.split(separator: "\n").first, line.hasPrefix("row-") else { return nil }
        return Int(line.dropFirst(4))
    }

    func testWheelScrollsAPagerOnTheAlternateScreen() throws {
        let host = try startLess(size: CGSize(width: 800, height: 240))
        defer { host.terminateProcess() }
        let start = try XCTUnwrap(firstRow(host))
        // AppKit turns a synthetic five-line wheel event into roughly that many rows (acceleration can
        // round it to four), so the test asks that the page moved, not by exactly how much.
        try wheel(5, on: host)
        XCTAssertTrue(
            waitFor { (self.firstRow(host) ?? start) < start },
            "wheel up moves less back through the file; visible:\n\(host.visibleText() ?? "")")
        try wheel(-5, on: host)
        XCTAssertTrue(waitFor { host.visibleText()?.contains("row-300") == true }, "and down again")
    }

    func testPagerRedrawsToTheNewSizeAfterAResize() throws {
        let host = try startLess(size: CGSize(width: 800, height: 400))
        defer { host.terminateProcess() }
        host.setFrameSize(CGSize(width: 800, height: 190))
        host.layoutSubtreeIfNeeded()
        let rows = host.terminalGrid.rows
        XCTAssertLessThan(rows, 15)
        // less redraws a page for the new height: the last line is still on screen, and the page
        // starts `rows - 1` lines above it, not where the taller page started.
        let firstShown = 300 - (rows - 1) + 1
        XCTAssertTrue(waitFor {
            guard let visible = host.visibleText() else { return false }
            return visible.contains("row-300") && visible.hasPrefix(String(format: "row-%03d", firstShown))
        }, "visible:\n\(host.visibleText() ?? "")")
    }

    func testExplicitTerminalCommandUsesPTYAndDoesNotRelaunchAfterExit() throws {
        let marker = directory.appendingPathComponent("launches.txt")
        let host = IDETerminalHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        let command = IDETerminalCommand(IDETerminalLaunch(
            executable: "/bin/sh",
            execName: "sh",
            arguments: ["-c", "test -t 0 && echo attached && echo launched >> \"$1\"", "sh", marker.path],
            environment: [:],
            directory: directory.path
        ))
        host.commandLaunch = command
        defer { host.terminateProcess() }
        host.layoutSubtreeIfNeeded()
        host.setActive(true)

        XCTAssertTrue(waitFor { host.visibleText()?.contains("attached") == true })
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.setActive(false)
        host.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let recreatedHost = IDETerminalHostView(frame: host.frame)
        recreatedHost.commandLaunch = command
        defer { recreatedHost.terminateProcess() }
        recreatedHost.setActive(true)
        recreatedHost.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "launched\n")
    }

    func testAlternateScrollBytes() {
        XCTAssertEqual(GhosttyAlternateScroll.bytes(rows: 2, applicationCursorKeys: false), Data("\u{1B}[A\u{1B}[A".utf8))
        XCTAssertEqual(GhosttyAlternateScroll.bytes(rows: -1, applicationCursorKeys: false), Data("\u{1B}[B".utf8))
        XCTAssertEqual(GhosttyAlternateScroll.bytes(rows: 1, applicationCursorKeys: true), Data("\u{1B}OA".utf8))
        XCTAssertEqual(GhosttyAlternateScroll.bytes(rows: 0, applicationCursorKeys: true), Data())
    }

    func testAlternateScreenAndScrollModeAreReported() throws {
        let terminal = try XCTUnwrap(GhosttyVtTerminal(cols: 40, rows: 10))
        XCTAssertFalse(terminal.isAlternateScreenActive)
        XCTAssertTrue(terminal.isModeSet(GhosttyTerminalModes.alternateScroll), "1007 is on by default, as in Ghostty")
        terminal.write(Data("\u{1B}[?1049h".utf8))
        XCTAssertTrue(terminal.isAlternateScreenActive)
        terminal.write(Data("\u{1B}[?1049l".utf8))
        XCTAssertFalse(terminal.isAlternateScreenActive)
    }
}
