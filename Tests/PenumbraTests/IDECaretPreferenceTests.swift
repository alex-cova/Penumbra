import AppKit
import XCTest
@testable import Penumbra
@testable import Umbra

/// Settings store the caret shape and an optional color, and push both onto an editor.
@MainActor
final class IDECaretPreferenceTests: XCTestCase {
    private var original: IDEPreferencesSnapshot?

    override func setUp() {
        super.setUp()
        original = IDEPreferences.shared.snapshot()
    }

    override func tearDown() {
        if let original {
            IDEPreferences.shared.restore(from: original)
        }
        super.tearDown()
    }

    func testApplyUsesTheChosenColorAndOtherwiseTheThemeText() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        IDEPreferences.shared.caretShape = .underline
        IDEPreferences.shared.caretColorHex = 0xE64553
        IDEPreferences.shared.apply(to: textView)

        XCTAssertEqual(textView.caretShape, .underline)
        XCTAssertEqual(sRGBHex(textView.insertionPointColor), 0xE64553)

        IDEPreferences.shared.caretColorHex = nil
        IDEPreferences.shared.apply(to: textView)
        XCTAssertEqual(textView.caretShape, .underline)
        XCTAssertEqual(sRGBHex(textView.insertionPointColor), sRGBHex(textView.theme.textColor))
    }

    func testOlderSnapshotsDefaultToAThemeColoredBar() throws {
        let snapshot = try XCTUnwrap(original)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        object?.removeValue(forKey: "caretShape")
        object?.removeValue(forKey: "caretColorHex")
        let stripped = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object))
        let decoded = try JSONDecoder().decode(IDEPreferencesSnapshot.self, from: stripped)
        XCTAssertEqual(decoded.caretShape, .bar)
        XCTAssertNil(decoded.caretColorHex)
    }

    private func sRGBHex(_ color: NSColor) -> UInt32? {
        guard let resolved = color.usingColorSpace(.sRGB) else { return nil }
        let red = UInt32((resolved.redComponent * 255).rounded())
        let green = UInt32((resolved.greenComponent * 255).rounded())
        let blue = UInt32((resolved.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }
}
