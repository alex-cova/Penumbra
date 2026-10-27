import XCTest
@testable import Umbra

/// VT parity fixtures for `GhosttyVtTerminal` (plan Step 3): recorded
/// escape-sequence transcripts fed through the parser, asserting the
/// plain-text snapshot and the OSC/query events the host layer needs.
final class GhosttyVtTerminalTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var list: [GhosttyVtEvent] = []
        func record(_ event: GhosttyVtEvent) {
            lock.withLock { list.append(event) }
        }
        func titles() -> [String] {
            lock.withLock {
                list.compactMap {
                    if case let .titleChanged(title) = $0 { return title }
                    return nil
                }
            }
        }
        func pwds() -> [String] {
            lock.withLock {
                list.compactMap {
                    if case let .pwdChanged(pwd) = $0 { return pwd }
                    return nil
                }
            }
        }
        func bells() -> Int {
            lock.withLock { list.filter { if case .bell = $0 { return true }; return false }.count }
        }
        func ptyReplies() -> [Data] {
            lock.withLock {
                list.compactMap {
                    if case let .writePty(data) = $0 { return data }
                    return nil
                }
            }
        }
    }

    private func terminal(cols: Int = 80, rows: Int = 24) -> (GhosttyVtTerminal, Events) {
        let events = Events()
        let term = GhosttyVtTerminal(cols: cols, rows: rows)
        XCTAssertNotNil(term, "terminal must be created")
        term!.onEvent = { [weak events] in events?.record($0) }
        return (term!, events)
    }

    func testPlainTextStripsSGR() {
        let (term, _) = terminal()
        term.write(Data("Hello \u{1B}[1mSwift\u{1B}[0m via xcframework!\r\n".utf8))
        let text = term.plainText()
        XCTAssertEqual(text?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello Swift via xcframework!")
    }

    func testTitleChangedViaOSC0() {
        let (term, events) = terminal()
        term.write(Data("\u{1B}]0;my title\u{07}".utf8))
        XCTAssertEqual(events.titles(), ["my title"])
    }

    func testTitleChangedViaOSC2() {
        let (term, events) = terminal()
        term.write(Data("\u{1B}]2;second title\u{07}".utf8))
        XCTAssertEqual(events.titles(), ["second title"])
    }

    func testPwdChangedViaOSC7() {
        let (term, events) = terminal()
        term.write(Data("\u{1B}]7;file://host/tmp/work\u{07}".utf8))
        XCTAssertEqual(events.pwds().count, 1, "OSC 7 must fire exactly one pwd event")
        XCTAssertTrue(events.pwds().first?.contains("/tmp/work") ?? false)
    }

    func testBell() {
        let (term, events) = terminal()
        term.write(Data([0x07]))
        XCTAssertEqual(events.bells(), 1)
    }

    func testCursorPositionQueryAnsweredViaWritePty() {
        let (term, events) = terminal()
        term.write(Data("\u{1B}[6n".utf8))
        XCTAssertEqual(events.ptyReplies(), [Data("\u{1B}[1;1R".utf8)])
    }

    func testAlternateScreenEnterExit() {
        let (term, _) = terminal()
        term.write(Data("main-screen".utf8))
        term.write(Data("\u{1B}[?1049h".utf8))
        term.write(Data("alt-screen".utf8))
        var text = term.plainText() ?? ""
        XCTAssertTrue(text.contains("alt-screen"), "active screen shows alternate content")
        XCTAssertFalse(text.contains("main-screen"), "primary screen hidden while alternate active")
        term.write(Data("\u{1B}[?1049l".utf8))
        text = term.plainText() ?? ""
        XCTAssertTrue(text.contains("main-screen"), "primary screen restored after exit")
    }

    func testScrollbackTail() {
        let (term, _) = terminal(rows: 24)
        var bytes = Data()
        for i in 1...30 { bytes.append(contentsOf: "line-\(i)\r\n".utf8) }
        term.write(bytes)
        XCTAssertEqual(term.recentText(lines: 5), "line-26\nline-27\nline-28\nline-29\nline-30")
    }

    func testRecentTextTrimsTrailingBlankLines() {
        let (term, _) = terminal()
        XCTAssertNil(term.recentText(lines: 10), "empty terminal has no recent text")
        term.write(Data("a\n\n\n".utf8))
        XCTAssertEqual(term.recentText(lines: 10), "a")
    }

    func testWideCharactersSurvive() {
        let (term, _) = terminal()
        term.write(Data("あいう\n".utf8))
        XCTAssertTrue(term.plainText()?.contains("あいう") ?? false)
    }

    func testOSC8HyperlinkKeepsLinkText() {
        let (term, _) = terminal()
        term.write(Data("\u{1B}]8;;https://example.com\u{07}link-text\u{1B}]8;;\u{07}\n".utf8))
        XCTAssertTrue(term.plainText()?.contains("link-text") ?? false)
    }

    func testScrollRegionDoesNotLoseContent() {
        let (term, _) = terminal()
        term.write(Data("\u{1B}[2;5r".utf8))
        term.write(Data("region-ok\n".utf8))
        term.write(Data("\u{1B}[r".utf8))
        XCTAssertTrue(term.plainText()?.contains("region-ok") ?? false)
    }

    func testResizeKeepsContent() {
        let (term, _) = terminal(cols: 80, rows: 24)
        term.write(Data("keep-me\n".utf8))
        term.resize(cols: 100, rows: 30)
        XCTAssertTrue(term.plainText()?.contains("keep-me") ?? false)
    }

    func testResetClearsScreen() {
        let (term, _) = terminal()
        term.write(Data("before-reset\n".utf8))
        XCTAssertNotNil(term.recentText(lines: 10))
        term.reset()
        XCTAssertNil(term.recentText(lines: 10))
    }
}
