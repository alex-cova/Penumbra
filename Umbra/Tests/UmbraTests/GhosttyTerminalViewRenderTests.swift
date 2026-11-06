import XCTest
@testable import Umbra

/// Off-screen render tests for `GhosttyTerminalView` (plan Step 4):
/// feed bytes through the parser, draw into a bitmap, assert real pixels.
@MainActor
final class GhosttyTerminalViewRenderTests: XCTestCase {
    private func makeView(size: CGSize = CGSize(width: 800, height: 480)) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(frame: NSRect(origin: .zero, size: size))
        view.applyFont(.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.applyColors(background: .black, foreground: .white, cursor: .white)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func nonBackgroundPixels(in view: GhosttyTerminalView) -> Int {
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("no bitmap rep")
            return 0
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Sample on a coarse grid: format-agnostic, fast enough.
        var hits = 0
        var y = 0
        while y < Int(rep.pixelsHigh) {
            var x = 0
            while x < Int(rep.pixelsWide) {
                if let color = rep.colorAt(x: x, y: y),
                   color.redComponent > 0.03 || color.greenComponent > 0.03 || color.blueComponent > 0.03 {
                    hits += 1
                }
                x += 6
            }
            y += 6
        }
        return hits
    }

    func testPlainTextDrawsPixels() {
        let view = makeView()
        view.feedOutput("hello world\r\n")
        XCTAssertGreaterThan(nonBackgroundPixels(in: view), 10, "drawn glyphs must differ from the background")
    }

    func testEmptyScreenDrawsBackgroundOnly() {
        let view = makeView()
        XCTAssertEqual(nonBackgroundPixels(in: view), 0, "cursor is hidden on a fresh terminal (no position)")
    }

    func testSGRBackedTextDiffersFromPlain() {
        let plain = makeView()
        plain.feedOutput("hello\r\n")
        let styled = makeView()
        styled.feedOutput("\u{1B}[7mhello\u{1B}[0m\r\n")
        XCTAssertGreaterThan(
            nonBackgroundPixels(in: styled),
            nonBackgroundPixels(in: plain),
            "inverse video must fill the run background")
    }

    func testResizeKeepsDrawing() {
        let view = makeView()
        view.feedOutput("resize me\r\n")
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(nonBackgroundPixels(in: view), 10)
    }

    // MARK: - Orientation (flipped-view CoreText regression)

    /// Small view for full bounding-box scans (fast at 2px sampling).
    /// Rep geometry was read off an ASCII dump, not assumed: rep (0,0) is
    /// the view's top-left, y grows down, x grows right.
    private func tinyView(fontSize: CGFloat = 12) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        view.applyFont(.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.applyColors(background: .black, foreground: .white, cursor: .white)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Ink bounding box of non-background pixels. All assertions built on
    /// this are relative (probe vs probe), never assuming which rep edge
    /// is up — `cacheDisplay` rep orientation is an implementation detail.
    private func inkBounds(in view: GhosttyTerminalView) -> (minX: Int, maxX: Int, minY: Int, maxY: Int, count: Int)? {
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("no bitmap rep")
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, count = 0
        var y = 0
        while y < Int(rep.pixelsHigh) {
            var x = 0
            while x < Int(rep.pixelsWide) {
                if let color = rep.colorAt(x: x, y: y),
                   color.redComponent > 0.03 || color.greenComponent > 0.03 || color.blueComponent > 0.03 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    count += 1
                }
                x += 2
            }
            y += 2
        }
        guard maxX >= minX else { return nil }
        return (minX, maxX, minY, maxY, count)
    }

    /// DECTCEM hide must take effect: hiding the cursor removes its block
    /// ink. (After "A\r\n" the cursor sits at row 1 col 0, under the glyph's
    /// columns, so widths match and only the pixel count drops.)
    func testHiddenCursorLeavesOnlyGlyphInk() {
        let shown = tinyView()
        shown.feedOutput("A\r\n")
        let hidden = tinyView()
        hidden.feedOutput("A\u{1B}[?25l\r\n")
        guard let s = inkBounds(in: shown), let h = inkBounds(in: hidden) else { return }
        XCTAssertLessThan(h.count, s.count, "hiding the cursor must remove the cursor-block ink")
    }

    /// Rows map to distinct bands, in order (row 0 above row 1 in rep space).
    func testRowsMapToDistinctBands() {
        let top = tinyView()
        top.feedOutput("X\u{1B}[?25l\r\n")
        let bottom = tinyView()
        bottom.feedOutput("\r\nX\u{1B}[?25l\r\n")
        guard let t = inkBounds(in: top), let b = inkBounds(in: bottom) else { return }
        let tCenter = t.minY + t.maxY, bCenter = b.minY + b.maxY
        XCTAssertLessThan(tCenter, bCenter, "row 0 must render above row 1")
        XCTAssertLessThanOrEqual(t.maxY, b.minY + 4, "row bands must not overlap")
    }

    /// Vertical ink centroid at 1px sampling, for the upright test below.
    private func inkCentroidY(in view: GhosttyTerminalView) -> Double? {
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("no bitmap rep")
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        var sum = 0, count = 0
        var y = 0
        while y < Int(rep.pixelsHigh) {
            var x = 0
            while x < Int(rep.pixelsWide) {
                if let color = rep.colorAt(x: x, y: y),
                   color.redComponent > 0.03 || color.greenComponent > 0.03 || color.blueComponent > 0.03 {
                    sum += y
                    count += 1
                }
                x += 1
            }
            y += 1
        }
        guard count > 0 else { return nil }
        return Double(sum) / Double(count)
    }

    /// Glyphs are upright, not rotated 180°: "V" (top-heavy) must centroid
    /// above "A" (bottom-heavy) in rep space, where y grows down. A 180°
    /// rotation swaps the two, so this fails on the old identity-matrix bug.
    func testGlyphsAreUprightNotRotated() {
        let v = tinyView(fontSize: 36)
        v.feedOutput("V\u{1B}[?25l\r\n")
        let a = tinyView(fontSize: 36)
        a.feedOutput("A\u{1B}[?25l\r\n")
        guard let vCenter = inkCentroidY(in: v), let aCenter = inkCentroidY(in: a) else { return }
        XCTAssertLessThan(vCenter, aCenter, "V's ink mass must sit above A's — glyphs upright, not rotated")
    }

    /// Glyph order runs left to right: "A" in column 0 must ink left of "A"
    /// in column 1. (Catches x-mirroring; the y tests above catch rotation.)
    func testGlyphOrderLeftToRight() {
        let left = tinyView()
        left.feedOutput("A\u{1B}[?25l\r\n")
        let right = tinyView()
        right.feedOutput(" A\u{1B}[?25l\r\n")
        guard let l = inkBounds(in: left), let r = inkBounds(in: right) else { return }
        XCTAssertLessThan(l.maxX, r.minX, "column 0 ink must sit left of column 1 ink")
    }

    /// Cells a tab (or cursor move) skips over are never written, but still take a column:
    /// `ls` pads its columns with tabs, and the gaps must not collapse.
    func testTabGapKeepsItsColumns() {
        let tabbed = tinyView()
        tabbed.feedOutput("A\tB\u{1B}[?25l\r\n")
        let spaced = tinyView()
        spaced.feedOutput("A       B\u{1B}[?25l\r\n")
        guard let t = inkBounds(in: tabbed), let s = inkBounds(in: spaced) else { return }
        XCTAssertEqual(t.maxX, s.maxX, "B after a tab must land in column 8, as after seven spaces")
    }

    // MARK: Settings ▸ Terminal

    private func settingsConfiguration(_ change: (inout IDETerminalSettings) -> Void) -> GhosttyTerminalViewConfiguration {
        var settings = IDETerminalSettings()
        change(&settings)
        return GhosttyTerminalViewConfiguration(
            settings: settings, scheme: (0xFFFFFF, 0x000000, 0xFFFFFF), termName: "xterm-256color")
    }

    func testRowHeightAdjustmentChangesHowManyRowsFit() {
        let view = makeView(size: CGSize(width: 800, height: 1200))
        let normal = view.gridLayout
        view.apply(settingsConfiguration { $0.cellHeightAdjustPercent = 50 })
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.gridLayout.cellHeight, normal.cellHeight)
        XCTAssertLessThan(view.gridLayout.rows, normal.rows)
        view.apply(settingsConfiguration { $0.cellHeightAdjustPercent = 0 })
        XCTAssertEqual(view.gridLayout.rows, normal.rows)
    }

    func testUnsafePasteRule() {
        XCTAssertFalse(GhosttyTerminalView.isUnsafePaste("ls -la", bracketed: false))
        XCTAssertTrue(GhosttyTerminalView.isUnsafePaste("ls\n", bracketed: false))
        XCTAssertTrue(GhosttyTerminalView.isUnsafePaste("a\rb", bracketed: false))
        XCTAssertFalse(GhosttyTerminalView.isUnsafePaste("ls\n", bracketed: true), "a bracketed paste is held back by the shell")
        XCTAssertTrue(GhosttyTerminalView.isUnsafePaste("x\u{1B}[201~rm -rf", bracketed: true), "it must not be able to close the bracket")
    }

    /// Runs `body` with the general pasteboard holding `text`, and puts back what was there.
    private func withPasteboard(_ text: String?, _ body: () -> Void) {
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        if let text { board.setString(text, forType: .string) }
        body()
        board.clearContents()
        if let saved { board.setString(saved, forType: .string) }
    }

    func testPasteWithLineBreaksAsksFirstWhenProtected() {
        let view = makeView()
        var questions: [String] = []
        view.confirm = { message, _, _, completion in
            questions.append(message)
            completion(false)
        }
        withPasteboard("echo hi\n") {
            view.pasteFromPasteboard()
            XCTAssertEqual(questions.count, 1)
            view.pasteFromPasteboard()
            XCTAssertEqual(questions.count, 2)
        }
    }

    func testPasteIsNotQuestionedWhenProtectionIsOffOrTheTextIsPlain() {
        let view = makeView()
        var asked = 0
        view.confirm = { _, _, _, completion in
            asked += 1
            completion(false)
        }
        withPasteboard("echo hi") {
            view.pasteFromPasteboard()
        }
        view.apply(settingsConfiguration { $0.confirmUnsafePaste = false })
        withPasteboard("echo hi\n") {
            view.pasteFromPasteboard()
        }
        XCTAssertEqual(asked, 0)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testClipboardReadAsksOnceWhilePending() {
        let view = makeView()
        view.apply(settingsConfiguration { $0.clipboardRead = .ask })
        var pending: [(Bool) -> Void] = []
        view.confirm = { _, _, _, completion in pending.append(completion) }
        view.feedOutput("\u{1B}]52;c;?\u{07}")
        XCTAssertTrue(waitUntil { pending.count == 1 })
        view.feedOutput("\u{1B}]52;c;?\u{07}")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(pending.count, 1, "a second request while the prompt is open does not stack another")
        pending[0](false)
        view.feedOutput("\u{1B}]52;c;?\u{07}")
        XCTAssertTrue(waitUntil { pending.count == 2 }, "after an answer the next request asks again")
    }

    func testClipboardWriteReachesThePasteboardOnlyWhenAllowed() {
        let view = makeView()
        withPasteboard("before") {
            view.apply(settingsConfiguration { $0.clipboardWrite = .deny })
            view.feedOutput("\u{1B}]52;c;aGVsbG8=\u{07}")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "before")

            view.apply(settingsConfiguration { $0.clipboardWrite = .allow })
            view.feedOutput("\u{1B}]52;c;aGVsbG8=\u{07}")
            XCTAssertTrue(waitUntil { NSPasteboard.general.string(forType: .string) == "hello" })
        }
    }

    func testDesktopNotificationsAndTitlesFollowTheirSwitches() {
        let view = makeView()
        var notifications: [String] = []
        var titles: [String] = []
        view.onDesktopNotification = { _, body in notifications.append(body) }
        view.onTitleUpdate = { titles.append($0) }

        view.feedOutput("\u{1B}]9;one\u{07}\u{1B}]2;first\u{07}")
        XCTAssertTrue(waitUntil { notifications == ["one"] && titles == ["first"] })

        view.apply(settingsConfiguration {
            $0.desktopNotifications = false
            $0.allowTitleChange = false
        })
        view.feedOutput("\u{1B}]9;two\u{07}\u{1B}]2;second\u{07}")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(notifications, ["one"])
        XCTAssertEqual(titles, ["first"])
    }
}
