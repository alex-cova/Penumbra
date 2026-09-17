import XCTest
@testable import Penumbra

@MainActor
final class DistractionFreeControllerTests: XCTestCase {
    func testTypingHidesChromeAndIdleRestoresIt() {
        let scheduler = TestScheduler()
        let controller = DistractionFreeController(scheduler: scheduler)
        var changes: [(Bool, TimeInterval)] = []
        controller.onVisibilityChange = { changes.append(($0, $1)) }
        controller.isEnabled = true

        controller.typingDidBegin()
        XCTAssertFalse(controller.isChromeVisible)
        XCTAssertEqual(changes.last?.0, false)
        XCTAssertEqual(changes.last?.1, 0.3)

        scheduler.runLatest()
        XCTAssertTrue(controller.isChromeVisible)
        XCTAssertEqual(changes.last?.0, true)
    }

    func testRepeatedTypingCancelsPreviousIdleRestore() {
        let scheduler = TestScheduler()
        let controller = DistractionFreeController(scheduler: scheduler)
        controller.isEnabled = true

        controller.typingDidBegin()
        let first = scheduler.tokens[0]
        controller.typingDidBegin()

        XCTAssertTrue(first.isCancelled)
        scheduler.run(at: 0)
        XCTAssertFalse(controller.isChromeVisible)
        scheduler.runLatest()
        XCTAssertTrue(controller.isChromeVisible)
    }

    func testMouseMovementRestoresChromeAndCancelsTimer() {
        let scheduler = TestScheduler()
        let controller = DistractionFreeController(scheduler: scheduler)
        controller.isEnabled = true
        controller.typingDidBegin()

        controller.mouseDidMove()

        XCTAssertTrue(controller.isChromeVisible)
        XCTAssertTrue(scheduler.tokens[0].isCancelled)
    }

    func testDisablingRestoresChromeWithoutAnimation() {
        let scheduler = TestScheduler()
        let controller = DistractionFreeController(scheduler: scheduler)
        var duration: TimeInterval?
        controller.onVisibilityChange = { _, value in duration = value }
        controller.isEnabled = true
        controller.typingDidBegin()

        controller.isEnabled = false

        XCTAssertTrue(controller.isChromeVisible)
        XCTAssertEqual(duration, 0)
        XCTAssertTrue(scheduler.tokens[0].isCancelled)
    }

    func testTextViewPublicDefaultsAndClamping() {
        let textView = makeFocusedTextView(text: "Text")

        XCTAssertFalse(textView.isDistractionFreeModeEnabled)
        XCTAssertEqual(textView.distractionFreeIdleDelay, 1.5)
        XCTAssertEqual(textView.distractionFreeFadeDuration, 0.3)
        XCTAssertTrue(textView.isDistractionFreeChromeVisible)

        textView.distractionFreeIdleDelay = -1
        textView.distractionFreeFadeDuration = -1
        XCTAssertEqual(textView.distractionFreeIdleDelay, 0)
        XCTAssertEqual(textView.distractionFreeFadeDuration, 0)
    }

    func testTextViewKeyAndMouseActivityUpdateOwnedAndHostChromeState() {
        let textView = makeFocusedTextView(text: "Text")
        let delegate = ChromeDelegate()
        textView.editorDelegate = delegate
        textView.distractionFreeFadeDuration = 0
        textView.isDistractionFreeModeEnabled = true

        send(keyEvent(keyCode: 0, characters: "a"), to: textView)

        XCTAssertFalse(textView.isDistractionFreeChromeVisible)
        XCTAssertEqual(delegate.lastVisibility, false)

        let mouseEvent = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: textView.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
        textView.mouseMoved(with: mouseEvent)

        XCTAssertTrue(textView.isDistractionFreeChromeVisible)
        XCTAssertEqual(delegate.lastVisibility, true)
    }
}

private final class ChromeDelegate: TextViewDelegate {
    var lastVisibility: Bool?

    func textView(_ textView: TextView,
                  didChangeDistractionFreeChromeVisibility isVisible: Bool,
                  transitionDuration: TimeInterval) {
        lastVisibility = isVisible
    }
}

private final class TestCancellation: DistractionFreeCancellation {
    var isCancelled = false
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }

    func run() {
        guard !isCancelled else { return }
        action()
    }
}

private final class TestScheduler: DistractionFreeScheduling {
    private(set) var tokens: [TestCancellation] = []

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> DistractionFreeCancellation {
        let token = TestCancellation(action: action)
        tokens.append(token)
        return token
    }

    func run(at index: Int) {
        tokens[index].run()
    }

    func runLatest() {
        tokens.last?.run()
    }
}
