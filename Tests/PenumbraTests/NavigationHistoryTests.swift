import XCTest
@testable import Penumbra

/// ⌘[ / ⌘] history: significance filtering, back/forward stack behaviour, and the capacity cap.
final class NavigationHistoryTests: XCTestCase {
    private func entry(_ line: Int, doc: UUID? = nil) -> NavigationEntry {
        NavigationEntry(documentID: doc, url: nil, location: TextLocation(lineNumber: line, column: 0))
    }

    func testSmallCursorMovesAreNotRecorded() {
        let history = NavigationHistory()
        history.noteCursor(entry(0))
        history.noteCursor(entry(3))
        history.noteCursor(entry(6))
        XCTAssertFalse(history.canGoBack)
    }

    func testSignificantJumpPushesPreviousPosition() {
        let history = NavigationHistory()
        history.noteCursor(entry(2))
        history.noteCursor(entry(40)) // > significantLineDelta
        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.goBack(from: entry(40))?.location.lineNumber, 2)
    }

    func testBackThenForwardReturnsToStart() {
        let history = NavigationHistory()
        history.recordCheckpoint(entry(10))
        let back = history.goBack(from: entry(80))
        XCTAssertEqual(back?.location.lineNumber, 10)
        let forward = history.goForward(from: entry(10))
        XCTAssertEqual(forward?.location.lineNumber, 80)
    }

    func testNewJumpClearsForwardStack() {
        let history = NavigationHistory()
        history.recordCheckpoint(entry(5))
        _ = history.goBack(from: entry(50))
        XCTAssertTrue(history.canGoForward)
        history.recordCheckpoint(entry(5))
        history.noteCursor(entry(5))
        history.noteCursor(entry(90))
        XCTAssertFalse(history.canGoForward, "A fresh significant move discards the forward stack")
    }

    func testDocumentSwitchIsAlwaysSignificant() {
        let history = NavigationHistory()
        let a = UUID(), b = UUID()
        history.noteCursor(entry(1, doc: a))
        history.noteCursor(entry(2, doc: b))
        XCTAssertEqual(history.goBack(from: entry(2, doc: b))?.documentID, a)
    }

    func testCapacityIsBounded() {
        let history = NavigationHistory()
        history.capacity = 3
        for line in stride(from: 0, through: 200, by: 20) {
            history.recordCheckpoint(entry(line))
        }
        XCTAssertLessThanOrEqual(history.backEntries.count, 3)
    }
}
