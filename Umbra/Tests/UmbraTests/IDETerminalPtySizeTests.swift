import XCTest
@testable import Umbra

/// The PTY, the VT grid and the drawn area must describe the same screen. A terminal that tells the
/// shell it has more rows than the view shows puts new output, the prompt and a pager's first page
/// (psql's column headers) where nobody can see them.
@MainActor
final class IDETerminalPtySizeTests: XCTestCase {
    /// The bottom panel's default height (220 pt) minus its toolbar row: about eleven rows of text.
    private let panelSize = CGSize(width: 800, height: 190)

    private func makeHost(size: CGSize) -> IDETerminalHostView {
        let host = IDETerminalHostView(frame: NSRect(origin: .zero, size: size))
        host.layoutSubtreeIfNeeded()
        return host
    }

    @discardableResult
    private func waitFor(timeout: TimeInterval = 20, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// Runs `script` with `/bin/sh` as the terminal's shell for the rest of the test.
    private func installScript(_ script: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-pty-size-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("script.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let preferences = IDEPreferences.shared
        let original = preferences.terminalShell
        var fixture = IDETerminalShellSettings()
        fixture.command = "/bin/sh"
        fixture.arguments = file.path
        fixture.loginShell = false
        preferences.terminalShell = fixture
        addTeardownBlock { @MainActor in
            preferences.terminalShell = original
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func reportedSize(in host: IDETerminalHostView) -> (rows: Int, cols: Int)? {
        guard let text = host.recentText(lines: 200),
              let range = text.range(of: #"size:(\d+) (\d+)"#, options: .regularExpression)
        else { return nil }
        let parts = text[range].dropFirst("size:".count).split(separator: " ")
        guard parts.count == 2, let rows = Int(parts[0]), let cols = Int(parts[1]) else { return nil }
        return (rows, cols)
    }

    func testPtyRowsAndColumnsAreTheVisibleGridInAShortPanel() throws {
        try installScript("printf 'size:%s\\n' \"$(stty size)\"\nexec /bin/sleep 60\n")
        let host = makeHost(size: panelSize)
        defer { host.terminateProcess() }
        host.setActive(true)
        XCTAssertTrue(waitFor { self.reportedSize(in: host) != nil }, "the shell must report its size")
        let size = try XCTUnwrap(reportedSize(in: host))
        let grid = host.terminalGrid
        let view = host.terminalView.bounds.size
        XCTAssertEqual(size.rows, grid.rows, "the PTY and the VT grid must agree")
        XCTAssertEqual(size.cols, grid.cols, "the PTY and the VT grid must agree")
        XCTAssertLessThanOrEqual(CGFloat(grid.rows) * grid.cellHeight, view.height,
                                 "every row the shell is told about must fit in the view")
        XCTAssertLessThanOrEqual(CGFloat(grid.cols) * grid.cellWidth, view.width,
                                 "every column the shell is told about must fit in the view")
        XCTAssertEqual(grid.rows, Int(view.height / grid.cellHeight), "no visible row is left unused")
    }

    func testNarrowPaneGetsItsOwnColumnCount() throws {
        try installScript("printf 'size:%s\\n' \"$(stty size)\"\nexec /bin/sleep 60\n")
        let host = makeHost(size: CGSize(width: 300, height: 400))
        defer { host.terminateProcess() }
        host.setActive(true)
        XCTAssertTrue(waitFor { self.reportedSize(in: host) != nil })
        let size = try XCTUnwrap(reportedSize(in: host))
        XCTAssertLessThan(size.cols, 80, "a 300 pt pane cannot show 80 columns")
        XCTAssertEqual(size.cols, host.terminalGrid.cols)
    }

    func testResizeReachesTheShell() throws {
        try installScript("""
            trap 'printf "size:%s\\n" "$(stty size)"' WINCH
            printf 'size:%s\\n' "$(stty size)"
            while :; do /bin/sleep 1; done

            """)
        let host = makeHost(size: CGSize(width: 800, height: 480))
        defer { host.terminateProcess() }
        host.setActive(true)
        XCTAssertTrue(waitFor { self.reportedSize(in: host)?.rows == host.terminalGrid.rows })
        host.setFrameSize(panelSize)
        host.layoutSubtreeIfNeeded()
        let expected = host.terminalGrid.rows
        XCTAssertLessThan(expected, 24)
        XCTAssertTrue(waitFor {
            guard let text = host.recentText(lines: 200) else { return false }
            return text.contains("size:\(expected) \(host.terminalGrid.cols)")
        }, "SIGWINCH must carry the new size to the shell")
    }

    /// psql column headers, end to end, in a terminal whose screen is already full. Opt-in: needs a
    /// local PostgreSQL and a database name in `UMBRA_PSQL_DB` (read-only query, local socket).
    func testPsqlHeadersAreVisibleInAShortPanel() throws {
        guard let database = ProcessInfo.processInfo.environment["UMBRA_PSQL_DB"], !database.isEmpty else {
            throw XCTSkip("set UMBRA_PSQL_DB to a local database to run")
        }
        let psql = ["/opt/homebrew/bin/psql", "/usr/local/bin/psql", "/usr/bin/psql"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let path = try XCTUnwrap(psql, "psql not found")
        try installScript("""
            i=0; while [ $i -lt 60 ]; do echo "filler $i"; i=$((i+1)); done
            \(path) -X --dbname '\(database)' -c "SELECT 1 AS id, 'Umbra' AS name;"
            echo psql-done
            exec /bin/sleep 60

            """)
        let host = makeHost(size: panelSize)
        defer { host.terminateProcess() }
        host.setActive(true)
        XCTAssertTrue(waitFor { host.recentText(lines: 200)?.contains("psql-done") == true }, "psql must run")
        let visible = host.visibleText() ?? ""
        XCTAssertTrue(visible.contains("id | name"), "the column headers must be on screen; visible:\n\(visible)")
        XCTAssertTrue(visible.contains("psql-done"), "the latest output must be on screen; visible:\n\(visible)")
    }
}
