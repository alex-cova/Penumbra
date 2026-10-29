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
}
