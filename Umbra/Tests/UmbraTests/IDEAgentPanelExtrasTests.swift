import AppKit
import XCTest

@testable import Umbra

/// The pure parts of the agent panel's small helpers: the prompt-length warning, Copy Path and image zoom.
@MainActor
final class IDEAgentPanelExtrasTests: XCTestCase {
    // MARK: - Prompt length

    func testNoWarningUpToTheLimit() {
        XCTAssertNil(IDEAgentComposerLimits.validationMessage(for: ""))
        XCTAssertNil(IDEAgentComposerLimits.validationMessage(for: String(repeating: "a", count: 10), limit: 10))
    }

    func testAMessageOverTheLimitIsWarnedAboutWithItsSize() throws {
        let message = try XCTUnwrap(IDEAgentComposerLimits.validationMessage(for: String(repeating: "a", count: 1_234), limit: 1_000))
        XCTAssertTrue(message.contains("1,234"), message)
        XCTAssertTrue(message.contains("1,000"), message)
        XCTAssertTrue(message.contains("still be sent"), "a warning, not a block")
    }

    // MARK: - Copy Path

    func testThePathOfAnEditsDiff() {
        XCTAssertEqual(IDEAgentPathCopy.path(fromUnifiedDiff: "--- a/src/A.java\n+++ b/src/A.java\n@@ -1 +1 @@\n-x\n+y\n"), "src/A.java")
        XCTAssertEqual(IDEAgentPathCopy.path(fromUnifiedDiff: "--- /dev/null\n+++ b/new file.txt\n@@ -0,0 +1 @@\n+y\n"), "new file.txt")
        XCTAssertEqual(IDEAgentPathCopy.path(fromUnifiedDiff: "--- a/gone.txt\n+++ /dev/null\n"), "gone.txt", "a removal names the old file")
        XCTAssertNil(IDEAgentPathCopy.path(fromUnifiedDiff: "@@ -1 +1 @@\n-x\n+y\n"))
    }

    func testCopyWritesThePathAsPlainText() {
        let board = NSPasteboard(name: NSPasteboard.Name("umbra.tests.copyPath.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        XCTAssertTrue(IDEAgentPathCopy.copy("src/A.java", to: board))
        XCTAssertEqual(board.string(forType: .string), "src/A.java")
    }

    // MARK: - Image zoom

    func testFitShrinksALargeImageAndLeavesASmallOneAtActualSize() {
        XCTAssertEqual(IDEAgentImageZoom.fit(image: CGSize(width: 2000, height: 1000), in: CGSize(width: 500, height: 500)), 0.25)
        XCTAssertEqual(IDEAgentImageZoom.fit(image: CGSize(width: 1000, height: 2000), in: CGSize(width: 800, height: 600)), 0.3)
        XCTAssertEqual(IDEAgentImageZoom.fit(image: CGSize(width: 100, height: 80), in: CGSize(width: 800, height: 600)), 1)
        XCTAssertEqual(IDEAgentImageZoom.fit(image: .zero, in: CGSize(width: 800, height: 600)), 1)
    }

    func testZoomStaysInItsRange() {
        XCTAssertEqual(IDEAgentImageZoom.fit(image: CGSize(width: 10_000, height: 10_000), in: CGSize(width: 100, height: 100)), 0.25)
        XCTAssertEqual(IDEAgentImageZoom.zoomIn(8), 8)
        XCTAssertEqual(IDEAgentImageZoom.zoomOut(0.25), 0.25)
        XCTAssertEqual(IDEAgentImageZoom.zoomIn(1), 1.25)
        XCTAssertEqual(IDEAgentImageZoom.zoomOut(1.25), 1)
    }
}
