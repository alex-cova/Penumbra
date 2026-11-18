import XCTest
import AppKit
@testable import Penumbra

/// Extension markers in the line-marker column: an SF Symbol with a semantic tint, a visible count when several share a line, and
/// accessibility buttons for what is drawn.
@MainActor
final class GutterExtensionMarkerTests: XCTestCase {
    private func custom(_ id: Int, line: Int, symbol: String = "leaf.fill", tint: GutterLineMarkerTint = .success,
                        label: String = "Spring bean", count: Int = 1) -> GutterLineMarker {
        GutterLineMarker(id: id, line: line, icon: .custom, tooltip: "tip \(id)",
                         symbol: GutterLineMarkerSymbol(name: symbol, tint: tint, accessibilityLabel: label), stackCount: count)
    }

    private func makeTextView(_ text: String) -> (TextView, NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.text = text
        window.contentView = textView
        textView.layoutIfNeeded()
        return (textView, window)
    }

    private func markerView(in textView: TextView) throws -> GutterLineMarkerView {
        func find(_ view: NSView) -> GutterLineMarkerView? {
            if let v = view as? GutterLineMarkerView { return v }
            for sub in view.subviews { if let v = find(sub) { return v } }
            return nil
        }
        return try XCTUnwrap(find(textView))
    }

    /// Alpha-weighted ink in `rect` after drawing the marker view, so "something was drawn there" is a measurable fact.
    private func ink(of view: GutterLineMarkerView, in rect: CGRect) throws -> Double {
        view.frame = CGRect(x: 0, y: 0, width: 32, height: 200)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var total = 0.0
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) where x >= 0 && y >= 0 && x < rep.pixelsWide && y < rep.pixelsHigh {
                total += Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return total
    }

    func testASymbolMarkerDrawsInItsSlotAndAnUnknownSymbolStillDoes() throws {
        let (textView, window) = makeTextView("one\ntwo\nthree\n")
        _ = window
        textView.setLineMarkers([custom(0, line: 2), custom(1, line: 3, symbol: "no.such.symbol.exists")])
        textView.layoutSubtreeIfNeeded()
        let view = try markerView(in: textView)
        let lineManager = try XCTUnwrap(view.lineManager)
        func slot(_ row: Int) -> CGRect {
            CGRect(x: 0, y: view.textContainerInsetTop + lineManager.yPosition(ofRow: row), width: GutterLineMarkerView.slotWidth, height: view.rowHeight)
        }
        XCTAssertGreaterThan(try ink(of: view, in: slot(1)), 0.5, "the symbol is drawn")
        XCTAssertGreaterThan(try ink(of: view, in: slot(2)), 0.5, "a symbol this macOS lacks falls back to a dot, never an empty slot")
        XCTAssertEqual(try ink(of: view, in: slot(0)), 0, accuracy: 0.01, "nothing on a line without a marker")
    }

    func testACountIsDrawnWhenMarkersShareALineAndTheirNumberIsHonest() throws {
        let (textView, window) = makeTextView("one\ntwo\n")
        _ = window
        textView.setLineMarkers([custom(0, line: 1, count: 1), custom(1, line: 2, count: 3)])
        textView.layoutSubtreeIfNeeded()
        let view = try markerView(in: textView)
        let lineManager = try XCTUnwrap(view.lineManager)
        let single = CGRect(x: 0, y: view.textContainerInsetTop + lineManager.yPosition(ofRow: 0), width: GutterLineMarkerView.slotWidth, height: view.rowHeight)
        let stacked = CGRect(x: 0, y: view.textContainerInsetTop + lineManager.yPosition(ofRow: 1), width: GutterLineMarkerView.slotWidth, height: view.rowHeight)
        XCTAssertGreaterThan(try ink(of: view, in: stacked), try ink(of: view, in: single), "the count badge adds ink")
    }

    func testMarkersTheHostDidNotStackAreStillCountedByTheGutter() throws {
        // Two stored markers on one line: only one slot, but the second is never silently dropped.
        let (textView, window) = makeTextView("one\ntwo\n")
        _ = window
        textView.setLineMarkers([custom(0, line: 2), custom(1, line: 2)])
        textView.layoutSubtreeIfNeeded()
        let view = try markerView(in: textView)
        let elements = try XCTUnwrap(view.accessibilityChildren()) as? [NSAccessibilityElement] ?? []
        XCTAssertEqual(elements.count, 1)
        XCTAssertTrue(elements[0].accessibilityLabel()?.contains("2 markers on line 2") == true, elements[0].accessibilityLabel() ?? "nil")
    }

    func testAccessibilityButtonsNameWhatTheyAreAndPressLikeAClick() throws {
        let (textView, window) = makeTextView("one\ntwo\nthree\n")
        _ = window
        var pressed: [Int] = []
        textView.lineMarkerHandler = { marker, _ in pressed.append(marker.id) }
        textView.setLineMarkers([custom(5, line: 2, label: "Spring controller")])
        textView.layoutSubtreeIfNeeded()
        let view = try markerView(in: textView)
        let elements = try XCTUnwrap(view.accessibilityChildren()) as? [NSAccessibilityElement] ?? []
        let element = try XCTUnwrap(elements.first)
        XCTAssertEqual(element.accessibilityRole(), .button)
        XCTAssertEqual(element.accessibilityLabel(), "Spring controller, line 2")
        XCTAssertEqual(element.accessibilityHelp(), "tip 5")
        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertEqual(pressed, [5], "pressing the accessibility button reaches the same handler as a click")
    }

    func testTintsMapToThemeColoursNotLiterals() {
        XCTAssertEqual(GutterLineMarkerGlyphs.color(for: .neutral), .secondaryLabelColor)
        XCTAssertEqual(GutterLineMarkerGlyphs.color(for: .accent), .controlAccentColor)
        XCTAssertEqual(GutterLineMarkerGlyphs.color(for: .success), .systemGreen)
        XCTAssertEqual(GutterLineMarkerGlyphs.color(for: .warning), .systemOrange)
        XCTAssertEqual(GutterLineMarkerGlyphs.color(for: .danger), .systemRed)
        XCTAssertEqual(Set(GutterLineMarkerTint.allCases.map { GutterLineMarkerGlyphs.color(for: $0).description }).count, GutterLineMarkerTint.allCases.count,
                       "every tint is distinguishable")
    }

    func testBuiltInMarkersAreUnchanged() {
        let m = GutterLineMarker(id: 1, line: 3, icon: .overriding, tooltip: "t")
        XCTAssertNil(m.symbol)
        XCTAssertEqual(m.stackCount, 1)
        XCTAssertEqual(GutterLineMarkerGlyphs.accessibilityLabel(for: .overriding), "Overriding method")
        XCTAssertEqual(GutterLineMarkerIcon.allCases.count, 7)
    }
}
