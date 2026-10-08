import AppKit
import XCTest
@testable import EditorIntelligence
@testable import Penumbra
@testable import Umbra

/// Tooltips wait half a second by default, and Umbra's setting reaches every kind of tooltip.
@MainActor
final class TooltipDelayTests: XCTestCase {
    private var original: IDEPreferencesSnapshot?
    private var originalNativeDelay: Any?

    override func setUp() {
        super.setUp()
        original = IDEPreferences.shared.snapshot()
        originalNativeDelay = UserDefaults.standard.object(forKey: "NSInitialToolTipDelay")
    }

    override func tearDown() {
        if let original {
            IDEPreferences.shared.restore(from: original)
        }
        if let originalNativeDelay {
            UserDefaults.standard.set(originalNativeDelay, forKey: "NSInitialToolTipDelay")
        } else {
            UserDefaults.standard.removeObject(forKey: "NSInitialToolTipDelay")
        }
        super.tearDown()
    }

    func testEngineDefaultsAreHalfASecond() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        XCTAssertEqual(textView.tooltipDelay, 0.5, accuracy: 0.0001)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )
        XCTAssertEqual(controller.tooltipDelay, 0.5, accuracy: 0.0001)
    }

    func testNegativeDelayIsClamped() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        textView.tooltipDelay = -1
        XCTAssertEqual(textView.tooltipDelay, 0)
    }

    func testPreferenceReachesTheEditorAndNativeTooltips() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        IDEPreferences.shared.tooltipDelayMilliseconds = 800
        IDEPreferences.shared.apply(to: textView)

        XCTAssertEqual(textView.tooltipDelay, 0.8, accuracy: 0.0001)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "NSInitialToolTipDelay"), 800)
    }
}
