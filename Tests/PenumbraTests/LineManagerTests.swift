import Foundation
@testable import Penumbra
import XCTest

final class LineManagerTests: XCTestCase {
    func testLineLength() {
        let data = DocumentLineNodeData(lineHeight: 0)
        data.totalLength = 6
        data.delimiterLength = 1
        XCTAssertEqual(data.length, 5)
        data.delimiterLength = 2
        XCTAssertEqual(data.length, 4)
    }

    func testRebuildFindsNewlinesAndLocations() {
        let lineManager = makeLineManager("aaa\nbbb\nccc")
        XCTAssertEqual(lineManager.lineCount, 3)
        XCTAssertEqual(lineManager.line(atRow: 0).location, 0)
        XCTAssertEqual(lineManager.line(atRow: 1).location, 4)
        XCTAssertEqual(lineManager.line(atRow: 2).location, 8)
        XCTAssertEqual(lineManager.line(containingCharacterAt: 0)?.index, 0)
        XCTAssertEqual(lineManager.line(containingCharacterAt: 4)?.index, 1)
        XCTAssertEqual(lineManager.line(containingCharacterAt: 8)?.index, 2)
        XCTAssertEqual(lineManager.line(containingCharacterAt: 11)?.index, 2)
    }

    func testContainingYOffsetClampsNegativeToFirstLine() {
        let lineManager = makeLineManager("aaa\nbbb\nccc")
        XCTAssertEqual(lineManager.line(containingYOffset: -350)?.index, 0)
        XCTAssertEqual(lineManager.line(containingYOffset: 0)?.index, 0)
        XCTAssertNotNil(lineManager.line(containingYOffset: lineManager.contentHeight))
    }

    func testInsertNewlineSplitsLine() {
        let lineManager = makeLineManager("aaabbb")
        _ = lineManager.insert("\n" as NSString, at: 3)
        XCTAssertEqual(lineManager.lineCount, 2)
        XCTAssertEqual(lineManager.line(atRow: 0).location, 0)
        XCTAssertEqual(lineManager.line(atRow: 1).location, 4)
    }

    func testRemoveCharactersMergesLines() {
        let lineManager = makeLineManager("aaa\nbbb")
        _ = lineManager.removeCharacters(in: NSRange(location: 3, length: 1))
        XCTAssertEqual(lineManager.lineCount, 1)
        XCTAssertEqual(lineManager.line(atRow: 0).data.totalLength, 6)
    }

    func testLinesInRangeDoesNotIncludeTheFollowingLineWhenSelectionEndsOnNewline() {
        let lineManager = makeLineManager("foo\nbar")
        let lines = lineManager.lines(in: NSRange(location: 0, length: 4))
        XCTAssertEqual(lines.map(\.index), [0])
        let startAndEnd = lineManager.startAndEndLine(in: NSRange(location: 0, length: 4))
        XCTAssertEqual(startAndEnd?.startLine.index, 0)
        XCTAssertEqual(startAndEnd?.endLine.index, 0)
    }

    func testRebuildManyShortLinesUsesFatLeaves() {
        let text = Array(repeating: "x", count: 200).joined(separator: "\n")
        let lineManager = makeLineManager(text)
        XCTAssertEqual(lineManager.lineCount, 200)
        XCTAssertEqual(lineManager.line(atRow: 0).location, 0)
        XCTAssertEqual(lineManager.line(atRow: 64).location, 64 * 2)
        XCTAssertEqual(lineManager.line(atRow: 199).index, 199)
    }

    /// Handles only the table references are released once it passes the prune threshold, so
    /// visiting every row doesn't keep one handle per line (~180 B each) forever.
    func testUnreferencedHandlesArePrunedAndHeldOnesKeepFollowingEdits() {
        let lineCount = LineManager.minimumHandlePruneThreshold * 3
        let lineManager = makeLineManager((0 ..< lineCount).map { "line \($0)" }.joined(separator: "\n"))
        let held = lineManager.line(atRow: 100)
        let heldFar = lineManager.line(atRow: lineCount - 10)
        let droppedID = lineManager.line(atRow: 50).id
        for row in 0 ..< lineCount {
            _ = lineManager.line(atRow: row)
        }
        XCTAssertLessThan(lineManager.handleCount, LineManager.minimumHandlePruneThreshold * 2 + 8)
        XCTAssertTrue(lineManager.line(atRow: 100) === held, "a held handle stays in the table")
        XCTAssertTrue(lineManager.line(atRow: lineCount - 10) === heldFar)
        XCTAssertEqual(lineManager.line(atRow: 50).id, droppedID, "a recreated handle keeps its ID")

        _ = lineManager.insert("new\n" as NSString, at: 0)
        XCTAssertEqual(held.row, 101, "a held handle still gets row updates")
        XCTAssertEqual(heldFar.row, lineCount - 9)
        XCTAssertEqual(lineManager.line(atRow: 101).id, held.id)
    }

    func testInitialLongestLineSurvivesPruningAndClearsWhenRemoved() {
        var lines = (0 ..< LineManager.minimumHandlePruneThreshold * 3).map { "line \($0)" }
        lines[7] = String(repeating: "x", count: 500)
        let text = lines.joined(separator: "\n")
        let lineManager = makeLineManager(text)
        XCTAssertEqual(lineManager.initialLongestLine?.row, 7)
        for row in 0 ..< lineManager.lineCount {
            _ = lineManager.line(atRow: row)
        }
        XCTAssertEqual(lineManager.initialLongestLine?.row, 7)
        XCTAssertEqual(lineManager.initialLongestLine?.data.totalLength, 501)

        let longest = lineManager.line(atRow: 7)
        _ = lineManager.removeCharacters(in: NSRange(location: longest.location - 1, length: longest.data.totalLength))
        XCTAssertNil(lineManager.initialLongestLine)
    }
}

private extension LineManagerTests {
    func makeLineManager(_ string: String) -> LineManager {
        let stringView = StringView(string: string)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        return lineManager
    }
}
