import XCTest
@testable import Penumbra

final class MetalActivationTests: XCTestCase {
    func testResolvedTable() {
        let cases: [(defaults: Bool?, property: Bool, device: Bool, expected: Bool, purpose: String)] = [
            (false, true, true, false, "process-wide kill switch"),
            (false, false, true, false, "kill switch with property off"),
            (false, true, false, false, "kill switch with no device"),
            (true, false, true, false, "embedder per-view disable wins over defaults true"),
            (true, false, false, false, "per-view disable with no device"),
            (true, true, true, true, "QA force-on"),
            (true, true, false, false, "QA force-on ignored without a device"),
            (nil, true, true, true, "absent defaults with property true"),
            (nil, false, true, false, "absent defaults with property false"),
            (nil, true, false, false, "absent defaults with no device"),
            (nil, false, false, false, "absent defaults, property off, no device")
        ]
        for testCase in cases {
            let actual = MetalActivation.resolved(
                property: testCase.property,
                deviceAvailable: testCase.device,
                defaults: testCase.defaults
            )
            XCTAssertEqual(
                actual,
                testCase.expected,
                "\(testCase.purpose): defaults=\(String(describing: testCase.defaults)) property=\(testCase.property) device=\(testCase.device)"
            )
        }
    }

    func testDefaultPropertyValueIsOffUnderXCTest() {
        XCTAssertTrue(MetalActivation.isRunningUnderXCTest, "the test process must be detected as XCTest")
        XCTAssertFalse(MetalActivation.defaultPropertyValue, "Metal defaults off under XCTest so the CG-path suite keeps exercising CG")
    }

    @MainActor
    func testTextViewDefaultsToMetalOffUnderXCTest() {
        // Production default is `true`; the XCTest guard keeps it `false` here.
        let textView = TextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        XCTAssertFalse(textView.isMetalRenderingEnabled)
        XCTAssertFalse(textView.isMetalRenderingActive)
    }

    @MainActor
    func testPerViewDisableBeatsUserDefaultsTrue() {
        let textView = TextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.isMetalRenderingEnabled = false
        XCTAssertFalse(textView.isMetalRenderingActive)
        XCTAssertEqual(
            MetalActivation.resolved(property: false, deviceAvailable: true, defaults: true),
            false
        )
    }
}
