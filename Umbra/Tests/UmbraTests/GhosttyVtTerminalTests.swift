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
        func clipboardWrites() -> [String] {
            lock.withLock {
                list.compactMap {
                    if case let .clipboardWrite(text) = $0 { return text }
                    return nil
                }
            }
        }
        func clipboardReadRequests() -> Int {
            lock.withLock { list.filter { if case .clipboardReadRequested = $0 { return true }; return false }.count }
        }
        func notifications() -> [(title: String, body: String)] {
            lock.withLock {
                list.compactMap {
                    if case let .desktopNotification(title, body) = $0 { return (title, body) }
                    return nil
                }
            }
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

    // MARK: Settings ▸ Terminal (GhosttyVtConfiguration)

    private func configured(_ change: (inout GhosttyVtConfiguration) -> Void) -> (GhosttyVtTerminal, Events) {
        let (term, events) = terminal()
        var config = GhosttyVtConfiguration()
        change(&config)
        term.configure(config)
        return (term, events)
    }

    private func firstCell(_ term: GhosttyVtTerminal) -> GhosttySnapshotCell? {
        term.renderSnapshot()?.grid.first?.cells.first
    }

    func testCustomPaletteChangesTheResolvedColor() {
        var palette = IDETerminalPalette.defaultANSI
        palette[1] = 0x112233
        let (term, _) = configured { $0.ansiPalette = palette }
        term.write(Data("\u{1B}[31mR".utf8))
        XCTAssertEqual(firstCell(term)?.fg, GhosttyRGB(r: 0x11, g: 0x22, b: 0x33))
    }

    func testPaletteBeyondTheSixteenAnsiColorsStaysTheBuiltInOne() {
        let (term, _) = configured { $0.ansiPalette = IDETerminalPalette.defaultANSI }
        // Index 196 is a cube color (pure red), which a 16-color override must not disturb.
        term.write(Data("\u{1B}[38;5;196mR".utf8))
        XCTAssertEqual(firstCell(term)?.fg, GhosttyRGB(r: 255, g: 0, b: 0))
    }

    func testNoPaletteRestoresTheBuiltInDefault() {
        let (term, _) = configured { $0.ansiPalette = [UInt32](repeating: 0x010203, count: 16) }
        term.write(Data("\u{1B}[31mR".utf8))
        XCTAssertEqual(firstCell(term)?.fg, GhosttyRGB(r: 1, g: 2, b: 3))
        // Configuring again with nil restores the built-in palette.
        term.configure(GhosttyVtConfiguration())
        term.write(Data("\u{1B}[2J\u{1B}[H\u{1B}[31mR".utf8))
        XCTAssertNotEqual(firstCell(term)?.fg, GhosttyRGB(r: 1, g: 2, b: 3))
    }

    func testDefaultColorsAreTheConfiguredOnes() {
        let (term, _) = configured {
            $0.foreground = 0xAABBCC
            $0.background = 0x102030
        }
        let snapshot = term.renderSnapshot()
        XCTAssertEqual(snapshot?.fg, GhosttyRGB(r: 0xAA, g: 0xBB, b: 0xCC))
        XCTAssertEqual(snapshot?.bg, GhosttyRGB(r: 0x10, g: 0x20, b: 0x30))
    }

    func testDefaultCursorFollowsTheConfigurationOnReset() {
        let (term, _) = configured {
            $0.cursorStyle = .underline
            $0.cursorBlinks = true
        }
        term.write(Data("\u{1B}[0 q".utf8))
        XCTAssertEqual(term.renderSnapshot()?.cursor.style, .underline)
        XCTAssertEqual(term.renderSnapshot()?.cursor.blinking, true)
        // A program's own choice wins until it resets.
        term.write(Data("\u{1B}[2 q".utf8))
        XCTAssertEqual(term.renderSnapshot()?.cursor.style, .block)
        XCTAssertEqual(term.renderSnapshot()?.cursor.blinking, false)
        term.write(Data("\u{1B}[0 q".utf8))
        XCTAssertEqual(term.renderSnapshot()?.cursor.style, .underline)
    }

    func testEachCursorStyleIsAvailableAsTheDefault() {
        let expected: [(IDETerminalCursorStyle, GhosttyCursorShape)] = [
            (.block, .block), (.bar, .bar), (.underline, .underline), (.hollow, .hollow),
        ]
        for (setting, shape) in expected {
            let (term, _) = configured { $0.cursorStyle = setting }
            term.write(Data("\u{1B}[0 q".utf8))
            XCTAssertEqual(term.renderSnapshot()?.cursor.style, shape, "\(setting)")
        }
    }

    func testScrollbackLimitTrimsHistory() {
        let flood = Data((1...5000).map { "line \($0)\r\n" }.joined().utf8)
        let (limited, _) = configured { $0.scrollbackLines = 50 }
        limited.write(flood)
        let (roomy, _) = configured { $0.scrollbackLines = 100_000 }
        roomy.write(flood)
        let limitedTotal = limited.scrollbar()?.total ?? 0
        let roomyTotal = roomy.scrollbar()?.total ?? 0
        // libghostty trims by page, so the limit is approximate: far below the flood, far above nothing.
        XCTAssertLessThan(limitedTotal, 1000)
        XCTAssertGreaterThan(roomyTotal, 4000)
    }

    func testTitleReportIsOffByDefaultAndOptIn() {
        let (off, offEvents) = configured { $0.titleReport = false }
        off.write(Data("\u{1B}]2;secret\u{07}\u{1B}[21t".utf8))
        XCTAssertFalse(offEvents.ptyReplies().contains { String(decoding: $0, as: UTF8.self).contains("secret") })

        let (on, onEvents) = configured { $0.titleReport = true }
        on.write(Data("\u{1B}]2;secret\u{07}\u{1B}[21t".utf8))
        XCTAssertTrue(onEvents.ptyReplies().contains { String(decoding: $0, as: UTF8.self).contains("secret") })
    }

    // OSC 52: "hello" is aGVsbG8=, "clip" is Y2xpcA==.

    func testClipboardWriteIsDeliveredWhenAllowed() {
        let (term, events) = configured { $0.clipboardWriteAllowed = true }
        term.write(Data("\u{1B}]52;c;aGVsbG8=\u{07}".utf8))
        XCTAssertEqual(events.clipboardWrites(), ["hello"])
    }

    func testClipboardWriteIsDroppedWhenDenied() {
        let (term, events) = configured { $0.clipboardWriteAllowed = false }
        term.write(Data("\u{1B}]52;c;aGVsbG8=\u{07}".utf8))
        XCTAssertEqual(events.clipboardWrites(), [])
    }

    private func repliedWithClip(_ events: Events) -> Bool {
        events.ptyReplies().contains { String(decoding: $0, as: UTF8.self).contains("Y2xpcA==") }
    }

    func testClipboardReadIsAnsweredWhenAllowed() {
        let (term, events) = configured { $0.clipboardRead = .allow }
        term.setClipboardReader { "clip" }
        term.write(Data("\u{1B}]52;c;?\u{07}".utf8))
        XCTAssertTrue(repliedWithClip(events))
        XCTAssertEqual(events.clipboardReadRequests(), 0)
    }

    func testClipboardReadIsRefusedWhenDenied() {
        let (term, events) = configured { $0.clipboardRead = .deny }
        term.setClipboardReader { "clip" }
        term.write(Data("\u{1B}]52;c;?\u{07}".utf8))
        XCTAssertFalse(repliedWithClip(events))
        XCTAssertEqual(events.clipboardReadRequests(), 0, "a denial is silent")
    }

    func testClipboardReadAsksFirstThenFollowsTheGrant() {
        let (term, events) = configured { $0.clipboardRead = .ask }
        term.setClipboardReader { "clip" }
        term.write(Data("\u{1B}]52;c;?\u{07}".utf8))
        XCTAssertFalse(repliedWithClip(events), "the first read is refused while the user decides")
        XCTAssertEqual(events.clipboardReadRequests(), 1)

        term.grantClipboardRead()
        term.write(Data("\u{1B}]52;c;?\u{07}".utf8))
        XCTAssertTrue(repliedWithClip(events), "after Allow, the program's next read is answered")
        XCTAssertEqual(events.clipboardReadRequests(), 1)
    }

    func testDesktopNotificationsFollowTheSwitch() {
        let (on, onEvents) = configured { $0.desktopNotifications = true }
        on.write(Data("\u{1B}]9;build finished\u{07}".utf8))
        on.write(Data("\u{1B}]777;notify;Title;Body text\u{07}".utf8))
        let received = onEvents.notifications()
        XCTAssertTrue(received.contains { $0.body == "build finished" }, "\(received)")
        XCTAssertTrue(received.contains { $0.title == "Title" && $0.body == "Body text" }, "\(received)")

        let (off, offEvents) = configured { $0.desktopNotifications = false }
        off.write(Data("\u{1B}]9;ignored\u{07}".utf8))
        XCTAssertEqual(offEvents.notifications().count, 0)
    }

    func testReconfiguringKeepsTheScreenContents() {
        let (term, _) = terminal()
        term.write(Data("keep me\r\n".utf8))
        term.configure(GhosttyVtConfiguration())
        XCTAssertTrue(term.plainText()?.contains("keep me") ?? false)
    }
}
