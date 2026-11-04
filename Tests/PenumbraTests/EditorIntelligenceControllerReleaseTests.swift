import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

/// F12: the controller starts a long-lived `for await` over its adapter's events. It must not hold
/// itself alive through it, or the controller of every closed editor stays in memory.
@MainActor
final class EditorIntelligenceControllerReleaseTests: XCTestCase {
    func testAControllerIsReleasedWhenItsEditorLetsGo() async {
        weak var weakController: EditorIntelligenceController?
        weak var weakTextView: TextView?
        do {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let textView = TextView(frame: window.contentView!.bounds)
            window.contentView = textView
            textView.text = "class A {}\n"
            let controller = EditorIntelligenceController(
                textView: textView,
                completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
                hoverEngine: HoverEngine(providers: []),
                diagnosticEngine: DiagnosticEngine(providers: [])
            )
            weakController = controller
            weakTextView = textView
            await Task.yield()
            window.contentView = nil
            window.close()
        }
        for _ in 0 ..< 100 where weakController != nil || weakTextView != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(weakController, "the controller outlived its text view")
        XCTAssertNil(weakTextView, "the text view outlived its controller")
    }

    func testBaselineATextViewAloneIsReleased() async {
        weak var weakTextView: TextView?
        do {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let textView = TextView(frame: window.contentView!.bounds)
            window.contentView = textView
            textView.text = "class A {}\n"
            weakTextView = textView
            await Task.yield()
            window.contentView = nil
            window.close()
        }
        for _ in 0 ..< 100 where weakTextView != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(weakTextView)
    }
}
