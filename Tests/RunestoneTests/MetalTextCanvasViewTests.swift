import AppKit
import XCTest
@testable import Runestone

@MainActor
final class MetalTextCanvasViewTests: XCTestCase {
    func testHitTestReturnsNil() {
        let canvas = MetalTextCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(canvas.hitTest(NSPoint(x: 50, y: 50)))
        XCTAssertNil(canvas.hitTest(NSPoint(x: 0, y: 0)))
        XCTAssertNil(canvas.hitTest(NSPoint(x: -10, y: -10)))
    }

    func testCanvasIsHiddenBehindFragmentsByDefault() {
        let textView = TextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.setState(TextViewState(text: "hello\nworld", theme: DefaultTheme()))
        textView.layoutIfNeeded()
        guard let textInputView = findTextInputView(in: textView) else {
            XCTFail("Expected TextInputView")
            return
        }
        let canvas = textInputView.subviews.compactMap { $0 as? MetalTextCanvasView }.first
        XCTAssertNotNil(canvas, "Canvas must exist in the hierarchy even when Metal is off")
        XCTAssertEqual(canvas?.isHidden, true)
        XCTAssertFalse(textView.isMetalRenderingActive)
        assertCanvasIsBehindFragmentContainer(in: textInputView)
    }

    func testEnablingMetalShowsTransparentCanvasAndRemovesFragmentViews() throws {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }
        let defaults = UserDefaults.standard.object(forKey: MetalActivation.defaultsKey) as? Bool
        guard MetalActivation.resolved(property: true, deviceAvailable: true, defaults: defaults) else {
            throw XCTSkip("Metal is disabled via UserDefaults kill switch")
        }
        let textView = TextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.setState(TextViewState(text: "hello\nworld", theme: DefaultTheme()))
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.isMetalRenderingActive)
        guard let textInputView = findTextInputView(in: textView) else {
            XCTFail("Expected TextInputView")
            return
        }
        let canvas = findMetalCanvas(in: textView)
        XCTAssertEqual(canvas?.isHidden, false)
        XCTAssertEqual((canvas?.layer as? CAMetalLayer)?.isOpaque, false)
        XCTAssertTrue(fragmentViews(in: textInputView).isEmpty, "Metal owns the glyph paint; no fragment views")
        XCTAssertTrue(
            canvas?.superview === textView,
            "Metal canvas must be a scroll-view overlay; CAMetalLayer inside NSClipView does not composite"
        )
    }

    func testDisablingMetalHidesCanvasAndKeepsFragmentViews() throws {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }
        let defaults = UserDefaults.standard.object(forKey: MetalActivation.defaultsKey) as? Bool
        guard MetalActivation.resolved(property: true, deviceAvailable: true, defaults: defaults) else {
            throw XCTSkip("Metal is disabled via UserDefaults kill switch")
        }
        let textView = TextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.setState(TextViewState(text: "hello\nworld", theme: DefaultTheme()))
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        textView.isMetalRenderingEnabled = false
        textView.layoutIfNeeded()
        XCTAssertFalse(textView.isMetalRenderingActive)
        guard let textInputView = findTextInputView(in: textView) else {
            XCTFail("Expected TextInputView")
            return
        }
        let canvas = findMetalCanvas(in: textView)
        XCTAssertEqual(canvas?.isHidden, true)
        XCTAssertFalse(fragmentViews(in: textInputView).isEmpty)
    }
}

private extension MetalTextCanvasViewTests {
    func findTextInputView(in root: NSView) -> TextInputView? {
        if let textInputView = root as? TextInputView {
            return textInputView
        }
        for subview in root.subviews {
            if let textInputView = findTextInputView(in: subview) {
                return textInputView
            }
        }
        return nil
    }

    func findMetalCanvas(in root: NSView) -> MetalTextCanvasView? {
        if let canvas = root as? MetalTextCanvasView {
            return canvas
        }
        for subview in root.subviews {
            if let canvas = findMetalCanvas(in: subview) {
                return canvas
            }
        }
        return nil
    }

    func fragmentViews(in root: NSView) -> [LineFragmentView] {
        var result: [LineFragmentView] = []
        if let fragment = root as? LineFragmentView {
            result.append(fragment)
        }
        for subview in root.subviews {
            result.append(contentsOf: fragmentViews(in: subview))
        }
        return result
    }

    func assertCanvasIsBehindFragmentContainer(in textInputView: TextInputView) {
        let subviews = textInputView.subviews
        guard let canvasIndex = subviews.firstIndex(where: { $0 is MetalTextCanvasView }) else {
            XCTFail("Expected MetalTextCanvasView in TextInputView")
            return
        }
        guard let linesIndex = subviews.firstIndex(where: { view in
            view.subviews.contains { $0 is LineFragmentView }
        }) else {
            XCTFail("Expected a line-fragment container after layoutIfNeeded")
            return
        }
        XCTAssertLessThan(canvasIndex, linesIndex, "Metal canvas must sit behind fragment views")
    }

}
