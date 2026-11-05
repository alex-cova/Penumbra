import Penumbra
import XCTest
@testable import Umbra

/// One pause captures the buffer once and runs visible work before the rest (F-02).
@MainActor
final class DocumentSettleCoordinatorTests: XCTestCase {
    private func makeTextView(_ text: String) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        textView.text = text
        return textView
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), message)
    }

    func testOnePauseCapturesTheTextOnceAndRunsVisibleWorkFirst() async {
        let settle = DocumentSettleCoordinator()
        let textView = makeTextView("one")
        var order: [String] = []
        settle.schedule(textView: textView, id: "import", phase: .language, after: .milliseconds(30)) { _, snapshot in
            order.append("language:\(snapshot.text)")
        }
        settle.schedule(textView: textView, id: "semantic", phase: .visible, after: .milliseconds(30)) { _, snapshot in
            order.append("visible:\(snapshot.text)")
        }
        textView.text = "two"
        await waitFor("both consumers ran") { order.count == 2 }
        XCTAssertEqual(order, ["visible:two", "language:two"])
        XCTAssertEqual(settle.snapshotCount, 1)
    }

    func testABurstOfKeystrokesCapturesTheTextOnce() async {
        let settle = DocumentSettleCoordinator()
        let textView = makeTextView("")
        var texts: [String] = []
        for index in 0..<12 {
            textView.insertText("x")
            settle.schedule(textView: textView, id: "semantic", phase: .visible, after: .milliseconds(40)) { _, snapshot in
                texts.append("visible:\(snapshot.text)")
            }
            settle.schedule(textView: textView, id: "import", phase: .language, after: .milliseconds(40)) { _, snapshot in
                texts.append("language:\(snapshot.text)")
            }
            if index == 11 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await waitFor("the pause ran") { texts.count == 2 }
        XCTAssertEqual(texts, ["visible:" + String(repeating: "x", count: 12), "language:" + String(repeating: "x", count: 12)])
        XCTAssertEqual(settle.snapshotCount, 1, "a burst is one settle, not one per keystroke")
    }

    func testAnImmediateRequestDoesNotFlushAPendingPause() async {
        let settle = DocumentSettleCoordinator()
        let textView = makeTextView("file")
        var ran = false
        settle.schedule(textView: textView, id: "structure", phase: .visible, after: .milliseconds(80)) { _, _ in
            ran = true
        }
        settle.schedule(textView: textView, id: "markers", phase: .visible, after: .zero) { _, snapshot in
            XCTAssertEqual(snapshot.text, "file")
            ran = true
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(ran, "a delay of zero must not flush a pause that is already waiting")
        await waitFor("the pause ran") { ran }
        XCTAssertEqual(settle.snapshotCount, 1)
    }

    func testAnImmediateRequestRunsWhenNothingIsWaiting() async {
        let settle = DocumentSettleCoordinator()
        let textView = makeTextView("file")
        var ran = false
        let started = ContinuousClock.now
        settle.schedule(textView: textView, id: "markers", phase: .visible, after: .zero) { _, snapshot in
            XCTAssertEqual(snapshot.text, "file")
            ran = true
        }
        await waitFor("the immediate settle ran") { ran }
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(200))
        XCTAssertEqual(settle.snapshotCount, 1)
    }

    func testAPauseDelayDoesNotRunOnAPendingImmediateSettle() async {
        let settle = DocumentSettleCoordinator()
        let textView = makeTextView("open")
        var ran = false
        settle.schedule(textView: textView, id: "semantic", phase: .visible, after: .zero) { _, _ in
            ran = true
        }
        settle.schedule(textView: textView, id: "structure", phase: .visible, after: .milliseconds(80)) { _, _ in
            ran = true
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(ran, "a caret move joined an immediate settle and ran before its own pause")
        await waitFor("the pause ran") { ran }
        XCTAssertEqual(settle.snapshotCount, 1)
    }
}
