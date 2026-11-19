import AppKit
import QuartzCore
import XCTest
@testable import Penumbra

/// The preview's entrance: it fades in and settles from a larger scale when it opens (only fades with Reduce
/// Motion), once the first parse is installed, and never on later edits.
final class MarkdownPreviewRevealTests: XCTestCase {
    @MainActor
    private func makeEditor() -> (NSWindow, TextView, MarkdownPreviewController) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let controller = MarkdownPreviewController(textView: textView)
        controller.parseDebounceNanoseconds = 0
        controller.embed(editorView: textView)
        window.contentView = controller.containerView
        window.orderFront(nil)
        textView.setState(TextViewState(text: "# Title\n\nBody text.", theme: DefaultTheme()))
        textView.languageIdentifier = "markdown"
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, textView, controller)
    }

    @MainActor
    private func reveal(_ controller: MarkdownPreviewController) -> CAAnimation? {
        controller.previewView.layer?.animation(forKey: MarkdownPreviewView.revealAnimationKey)
    }

    @MainActor
    func testOpeningPlaysTheEntranceOnceTheFirstParseIsIn() async {
        let (window, textView, controller) = makeEditor()
        defer { window.close() }

        XCTAssertTrue(controller.toggle())
        XCTAssertTrue(controller.debugRevealPending)
        XCTAssertEqual(controller.previewView.alphaValue, 0, "hidden until the new document is laid out")
        XCTAssertNil(reveal(controller))

        await controller.waitForPendingWork()
        XCTAssertFalse(controller.debugRevealPending)
        XCTAssertNotNil(controller.previewView.document)
        // It plays in the layout pass that lays the new document out (the window may already
        // have run it while the parse was awaited).
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.previewView.debugRevealsAfterLayout)
        XCTAssertEqual(controller.previewView.alphaValue, 1)
        XCTAssertNotNil(reveal(controller))

        // An edit re-renders without animating again.
        controller.previewView.layer?.removeAnimation(forKey: MarkdownPreviewView.revealAnimationKey)
        textView.insertText("!")
        controller.noteTextDidChange()
        await controller.waitForPendingWork()
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNil(reveal(controller))
    }

    @MainActor
    func testClosingBeforeTheParseLandsLeavesThePageVisible() {
        let (window, _, controller) = makeEditor()
        defer { window.close() }
        controller.toggle()
        controller.toggle()
        XCTAssertFalse(controller.debugRevealPending)
        XCTAssertEqual(controller.previewView.alphaValue, 1)
    }

    @MainActor
    func testSwitchedOffTheEntranceDoesNotPlay() async {
        let (window, _, controller) = makeEditor()
        defer { window.close() }
        controller.options.animatesAppearance = false
        controller.toggle()
        XCTAssertEqual(controller.previewView.alphaValue, 1)
        await controller.waitForPendingWork()
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNil(reveal(controller))
    }

    @MainActor
    func testReduceMotionOnlyFades() throws {
        let view = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.playRevealAnimation(reduceMotion: true)
        let group = try XCTUnwrap(view.layer?.animation(forKey: MarkdownPreviewView.revealAnimationKey) as? CAAnimationGroup)
        XCTAssertEqual(group.animations?.compactMap { ($0 as? CAPropertyAnimation)?.keyPath }, ["opacity"])

        view.playRevealAnimation(reduceMotion: false)
        let full = try XCTUnwrap(view.layer?.animation(forKey: MarkdownPreviewView.revealAnimationKey) as? CAAnimationGroup)
        XCTAssertEqual(full.animations?.compactMap { ($0 as? CAPropertyAnimation)?.keyPath }, ["opacity", "transform"])
    }

    /// The page scales around its center: AppKit layers anchor at a corner, so a plain scale would
    /// push it out from the bottom-left.
    @MainActor
    func testTheScaleIsCenteredOnThePage() throws {
        let view = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.playRevealAnimation(reduceMotion: false)
        let group = try XCTUnwrap(view.layer?.animation(forKey: MarkdownPreviewView.revealAnimationKey) as? CAAnimationGroup)
        let grow = try XCTUnwrap(group.animations?.last as? CABasicAnimation)
        let start = try XCTUnwrap((grow.fromValue as? NSValue)?.caTransform3DValue)
        let center = CGPoint(x: 200, y: 150)
        let mapped = CGPoint(
            x: center.x * start.m11 + center.y * start.m21 + start.m41,
            y: center.x * start.m12 + center.y * start.m22 + start.m42
        )
        XCTAssertEqual(mapped.x, center.x, accuracy: 0.01)
        XCTAssertEqual(mapped.y, center.y, accuracy: 0.01)
        XCTAssertEqual(start.m11, MarkdownPreviewView.revealStartScale, accuracy: 0.0001)
        XCTAssertGreaterThan(start.m11, 1, "starts big and settles down to size")
    }
}
