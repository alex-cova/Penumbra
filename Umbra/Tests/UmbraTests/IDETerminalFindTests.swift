import AppKit
import XCTest
@testable import Umbra

/// ⌘F in the terminal: the per-session find bar on `IDETerminalHostView`, its keys, focus hand-back,
/// and the routing in `IDEWorkspace.showFind` (terminal focused → terminal search, else the editor's).
/// Mirror tabs feed text with no shell behind it, so the output is exact.
@MainActor
final class IDETerminalFindTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 600))
    }

    override func tearDown() {
        window.close()
        window = nil
        super.tearDown()
    }

    private func makeHost(frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 240), lines: Int = 500, prefix: String = "line") -> IDETerminalHostView {
        let host = IDETerminalHostView(frame: frame)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        host.setMirrorsOutput(true)
        host.setActive(true)
        var text = ""
        for index in 0..<lines { text += String(format: "\(prefix)-%04d\r\n", index) }
        host.feedOutput(text)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(waitFor { host.recentText(lines: 3)?.contains(String(format: "\(prefix)-%04d", lines - 1)) == true })
        window.makeFirstResponder(host.terminalView)
        return host
    }

    @discardableResult
    private func waitFor(timeout: TimeInterval = 10, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return check()
    }

    private func type(_ text: String, into bar: GhosttyTerminalFindBar) {
        bar.queryDelay = .zero
        bar.query = text
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.searchField))
    }

    private func press(_ selector: Selector, in bar: GhosttyTerminalFindBar, shift: Bool = false) {
        bar.isShiftDown = { shift }
        _ = bar.control(bar.searchField, textView: NSTextView(), doCommandBy: selector)
    }

    func testFindBarOpensFocusedAndCountsMatchesInScrollback() throws {
        let host = makeHost()
        host.showFindBar()
        let bar = try XCTUnwrap(host.findBar)
        XCTAssertTrue(host.isFindBarVisible)
        XCTAssertTrue(IDETerminalHostView.owning(window.firstResponder) === host,
                      "the field (through its field editor) has the keyboard and belongs to this session")
        type("line-01", into: bar)
        XCTAssertTrue(waitFor { bar.statusText == "1 of 100" }, "got \(bar.statusText)")
    }

    func testReturnAndShiftReturnWalkTheMatches() throws {
        let host = makeHost()
        host.showFindBar()
        let bar = try XCTUnwrap(host.findBar)
        type("line-01", into: bar)
        XCTAssertTrue(waitFor { bar.statusText == "1 of 100" })
        press(#selector(NSResponder.insertNewline(_:)), in: bar)
        XCTAssertEqual(bar.statusText, "2 of 100", "Return: the next, older match")
        press(#selector(NSResponder.insertNewline(_:)), in: bar)
        XCTAssertEqual(bar.statusText, "3 of 100")
        press(#selector(NSResponder.insertNewline(_:)), in: bar, shift: true)
        XCTAssertEqual(bar.statusText, "2 of 100", "Shift-Return: back toward newer output")
        XCTAssertTrue(host.visibleText()?.contains("line-0198") == true, "the match is scrolled into view")
    }

    func testEscapeClosesTheBarAndReturnsTheKeyboardToTheTerminal() throws {
        let host = makeHost()
        host.showFindBar()
        let bar = try XCTUnwrap(host.findBar)
        type("line-02", into: bar)
        XCTAssertTrue(waitFor { bar.statusText.hasSuffix("of 100") })
        press(#selector(NSResponder.cancelOperation(_:)), in: bar)
        XCTAssertFalse(host.isFindBarVisible)
        XCTAssertTrue(window.firstResponder === host.terminalView)

        host.showFindBar()
        XCTAssertEqual(bar.query, "line-02", "reopening keeps the last search")
        XCTAssertTrue(waitFor { bar.statusText.hasSuffix("of 100") })
    }

    func testNoMatchesSaysSo() throws {
        let host = makeHost()
        host.showFindBar()
        let bar = try XCTUnwrap(host.findBar)
        type("nothing-like-this", into: bar)
        XCTAssertTrue(waitFor { bar.statusText == "No matches" }, "got \(bar.statusText)")
    }

    func testSearchStaysInItsOwnSession() throws {
        let first = makeHost(frame: NSRect(x: 0, y: 0, width: 480, height: 240), prefix: "alpha")
        let second = makeHost(frame: NSRect(x: 500, y: 0, width: 480, height: 240), prefix: "beta")
        window.makeFirstResponder(first.terminalView)
        first.showFindBar()
        let bar = try XCTUnwrap(first.findBar)
        type("alpha-00", into: bar)
        XCTAssertTrue(waitFor { bar.statusText == "1 of 100" })
        press(#selector(NSResponder.insertNewline(_:)), in: bar)
        XCTAssertNil(second.findBar, "the other session has no bar")
        XCTAssertTrue(second.visibleText()?.contains("beta-0499") == true, "nor did its viewport move")
    }

    func testShowFindRoutesToTheFocusedTerminalOnly() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer { IDEWorkspace.isSessionPersistenceEnabled = true }
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.window = window
        let host = makeHost()

        let editorStandIn = NSTextView(frame: NSRect(x: 0, y: 300, width: 300, height: 200))
        window.contentView?.addSubview(editorStandIn)
        window.makeFirstResponder(editorStandIn)
        // A bare workspace has no editor adapter to call into, so the editor side is checked at the
        // routing decision: nothing outside a terminal resolves to a terminal session.
        XCTAssertNil(IDETerminalHostView.owning(window.firstResponder), "⌘F in the editor is the editor's find")
        XCTAssertFalse(host.isFindBarVisible)

        window.makeFirstResponder(host.terminalView)
        workspace.showFind()
        XCTAssertTrue(host.isFindBarVisible, "⌘F in the terminal opens the terminal's find bar")
        XCTAssertTrue(IDETerminalHostView.owning(window.firstResponder) === host)

        // ⌘F again from the bar's own field keeps it open and focused.
        workspace.showFind()
        XCTAssertTrue(host.isFindBarVisible)
        XCTAssertTrue(IDETerminalHostView.owning(window.firstResponder) === host)
    }

    func testStatusText() {
        var state = GhosttySearchState(status: .complete, total: 12, selectedIndex: 2, highlights: [])
        XCTAssertEqual(GhosttyTerminalFindBar.statusText(for: state, query: "x"), "3 of 12")
        state.status = .searching
        XCTAssertEqual(GhosttyTerminalFindBar.statusText(for: state, query: "x"), "3 of 12+")
        state.selectedIndex = nil
        XCTAssertEqual(GhosttyTerminalFindBar.statusText(for: state, query: "x"), "12 matches+")
        state.total = 0
        XCTAssertEqual(GhosttyTerminalFindBar.statusText(for: state, query: "x"), "Searching…")
        state.status = .complete
        XCTAssertEqual(GhosttyTerminalFindBar.statusText(for: state, query: "x"), "No matches")
        XCTAssertEqual(GhosttyTerminalFindBar.statusText(for: state, query: ""), "")
    }
}
