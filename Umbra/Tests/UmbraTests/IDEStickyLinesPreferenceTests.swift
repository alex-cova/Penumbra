import AppKit
import XCTest
@testable import Penumbra
@testable import Umbra

/// Settings switch sticky lines on and off per editor, for all languages or one.
@MainActor
final class IDEStickyLinesPreferenceTests: XCTestCase {
    private var original: (show: Bool, maximum: Int, disabled: [String])?

    override func setUp() {
        super.setUp()
        let preferences = IDEPreferences.shared
        original = (preferences.showStickyLines, preferences.maximumStickyLines, preferences.stickyLinesDisabledLanguages)
    }

    override func tearDown() {
        if let original {
            let preferences = IDEPreferences.shared
            preferences.showStickyLines = original.show
            preferences.maximumStickyLines = original.maximum
            preferences.stickyLinesDisabledLanguages = original.disabled
        }
        super.tearDown()
    }

    private func makeTextView(language: String?) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.languageIdentifier = language
        return textView
    }

    func testSettingsReachTheEditor() {
        IDEPreferences.shared.showStickyLines = true
        IDEPreferences.shared.maximumStickyLines = 3
        IDEPreferences.shared.stickyLinesDisabledLanguages = []
        let textView = makeTextView(language: "java")
        IDEPreferences.shared.apply(to: textView)

        XCTAssertTrue(textView.showsStickyLines)
        XCTAssertEqual(textView.maximumStickyLineCount, 3)
    }

    func testDisabledLanguageTurnsThemOffOnlyThere() {
        IDEPreferences.shared.showStickyLines = true
        IDEPreferences.shared.stickyLinesDisabledLanguages = ["python"]
        let python = makeTextView(language: "python")
        let java = makeTextView(language: "java")
        IDEPreferences.shared.apply(to: python)
        IDEPreferences.shared.apply(to: java)

        XCTAssertFalse(python.showsStickyLines)
        XCTAssertTrue(java.showsStickyLines)
    }

    func testContextMenuDisableHandlersUpdateTheSettings() {
        IDEPreferences.shared.showStickyLines = true
        IDEPreferences.shared.stickyLinesDisabledLanguages = []
        let textView = makeTextView(language: "java")
        IDEPreferences.shared.apply(to: textView)

        textView.stickyLinesDisableHandler?(true)
        XCTAssertEqual(IDEPreferences.shared.stickyLinesDisabledLanguages, ["java"])
        XCTAssertTrue(IDEPreferences.shared.showStickyLines)

        textView.stickyLinesDisableHandler?(false)
        XCTAssertFalse(IDEPreferences.shared.showStickyLines)
    }

    func testMaximumIsClamped() {
        let textView = makeTextView(language: nil)
        textView.maximumStickyLineCount = 99
        XCTAssertEqual(textView.maximumStickyLineCount, 10)
        textView.maximumStickyLineCount = 0
        XCTAssertEqual(textView.maximumStickyLineCount, 1)
    }
}
