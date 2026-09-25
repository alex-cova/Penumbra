@preconcurrency import AppKit
@testable import Penumbra
import XCTest

/// Layout used to keep a `LineController` (typesetting, ~6 KB) for every line ever laid out:
/// ~900 MB after scrolling through a 120k-line file. It now evicts controllers far from the
/// viewport once past a cap.
final class LineControllerEvictionTests: XCTestCase {
    func testStorageEvictsOutsideKeptRowsOnlyPastTheLimit() {
        let text = (0 ..< 100).map { "line \($0)" }.joined(separator: "\n")
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let storage = LineControllerStorage(
            stringView: stringView,
            lineControllerFactory: LineControllerFactory(
                stringView: stringView,
                highlightService: HighlightService(lineManager: lineManager),
                invisibleCharacterConfiguration: InvisibleCharacterConfiguration()))
        for row in 0 ..< 100 {
            _ = storage.getOrCreateLineController(for: lineManager.line(atRow: row))
        }
        XCTAssertEqual(storage.evictLineControllers(ifMoreThan: 100, keepingRows: 40 ... 59), 0)
        XCTAssertEqual(storage.numberOfLineControllers, 100)

        let pinned = lineManager.line(atRow: 5).id
        XCTAssertEqual(storage.evictLineControllers(ifMoreThan: 50, keepingRows: 40 ... 59, pinnedLineIDs: [pinned]), 79)
        XCTAssertEqual(storage.numberOfLineControllers, 21)
        XCTAssertNotNil(storage[pinned])
        XCTAssertNotNil(storage[lineManager.line(atRow: 40).id])
        XCTAssertNil(storage[lineManager.line(atRow: 39).id])
        XCTAssertNil(storage[lineManager.line(atRow: 60).id])
    }

    @MainActor
    func testScrollingALongDocumentKeepsControllersBoundedAndCaretMovementWorking() {
        let originalMinimum = EditorPerformanceConstants.minimumRetainedLineControllers
        EditorPerformanceConstants.minimumRetainedLineControllers = 200
        defer { EditorPerformanceConstants.minimumRetainedLineControllers = originalMinimum }

        let lines = (0 ..< 5_000).map { index in
            index == 3 ? "a much longer line that sets the content width " + String(repeating: "w", count: 120) : "line \(index)"
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: lines.joined(separator: "\n")))
        textView.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        textView.selectedRange = NSRange(location: 2, length: 0)
        textView.layoutIfNeeded()
        let contentWidth = textView.contentSize.width
        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height * 50)

        var offsetY: CGFloat = 0
        while offsetY < textView.contentSize.height {
            textView.contentOffset = CGPoint(x: 0, y: offsetY)
            textView.layoutIfNeeded()
            offsetY += textView.bounds.height
        }
        XCTAssertLessThanOrEqual(textView.lineControllerCountForTesting, 400, "controllers stay bounded")
        let lineManager = textView.minimapViewForTesting.lineDataSource!.lineManager
        XCTAssertLessThan(lineManager.handleCount, 1_000, "handles are released with their controllers")
        XCTAssertEqual(textView.contentSize.width, contentWidth, "evicting controllers keeps line widths")

        // The caret line (row 0) is far from the viewport now; moving down must still work.
        let textInputView = textView.minimapViewForTesting.lineDataSource!
        textInputView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let line1Start = (lines[0] as NSString).length + 1
        XCTAssertEqual(textView.selectedRange, NSRange(location: line1Start + 2, length: 0))
    }
}
