import AppKit
import XCTest
@testable import Penumbra

final class TextViewSmokeTests: XCTestCase {
    func testDefaultThemeProvidesEditorColors() {
        let theme = DefaultTheme()
        XCTAssertGreaterThan(theme.font.pointSize, 0)
        XCTAssertGreaterThan(theme.textColor.cgColor.alpha, 0)
        XCTAssertGreaterThan(theme.selectionColor.cgColor.alpha, 0)
    }

    func testDefaultThemeSelectionColorIsOpaqueBlue() {
        let theme = DefaultTheme()
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let converted = theme.selectionColor.usingColorSpace(.sRGB) ?? theme.selectionColor
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(alpha, 1, accuracy: 0.01)
        XCTAssertEqual(red, 59 / 255, accuracy: 0.02)
        XCTAssertEqual(green, 130 / 255, accuracy: 0.02)
        XCTAssertEqual(blue, 246 / 255, accuracy: 0.02)
    }

    func testApplyingThemeSetsSelectionHighlightColor() {
        let textView = TextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.selectionHighlightColor = .systemRed
        let theme = DefaultTheme()
        textView.theme = theme
        var expectedRed: CGFloat = 0
        var expectedGreen: CGFloat = 0
        var expectedBlue: CGFloat = 0
        var expectedAlpha: CGFloat = 0
        var actualRed: CGFloat = 0
        var actualGreen: CGFloat = 0
        var actualBlue: CGFloat = 0
        var actualAlpha: CGFloat = 0
        let expected = theme.selectionColor.usingColorSpace(.sRGB) ?? theme.selectionColor
        let actual = textView.selectionHighlightColor.usingColorSpace(.sRGB) ?? textView.selectionHighlightColor
        expected.getRed(&expectedRed, green: &expectedGreen, blue: &expectedBlue, alpha: &expectedAlpha)
        actual.getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &actualAlpha)
        XCTAssertEqual(actualRed, expectedRed, accuracy: 0.01)
        XCTAssertEqual(actualGreen, expectedGreen, accuracy: 0.01)
        XCTAssertEqual(actualBlue, expectedBlue, accuracy: 0.01)
        XCTAssertEqual(actualAlpha, expectedAlpha, accuracy: 0.01)
    }

    func testSetStateWithSelectionDoesNotCrashWhenApplyingTheme() {
        let textView = TextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.setState(TextViewState(text: "short", theme: DefaultTheme()))
        textView.selectedRange = NSRange(location: 0, length: 5)
        // Longer replacement + new theme: selectionHighlightColor applies mid-setState
        // after stringView swap but before lineManager swap — must not assert.
        textView.selectionHighlightColor = .systemRed
        let longer = TextViewState(text: "a much longer document body", theme: DefaultTheme())
        textView.setState(longer)
        XCTAssertEqual(textView.text, "a much longer document body")
    }

    func testTextViewStateInitializesForPlainText() {
        let state = TextViewState(text: "hello\nworld", theme: DefaultTheme())
        XCTAssertEqual(state.stringView.string as String, "hello\nworld")
        XCTAssertNotNil(state.lineManager)
    }
}
