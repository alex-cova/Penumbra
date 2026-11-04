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

    /// Lines keep the estimate as their height until typeset; a new estimate must reach them
    /// (across leaves) and leave typeset and folded lines alone.
    func testChangingEstimateMovesOnlyLinesStillAtTheOldEstimate() {
        let lineManager = makeLineManager((0 ..< 1_000).map { "line \($0)" }.joined(separator: "\n"))
        lineManager.estimatedLineHeight = 20
        let typeset = lineManager.line(atRow: 500)
        lineManager.setHeight(of: typeset, to: 33)
        lineManager.setHeight(of: lineManager.line(atRow: 700), to: 0)

        lineManager.estimatedLineHeight = 16

        XCTAssertEqual(lineManager.lineInfo(atRow: 0).lineHeight, 16)
        XCTAssertEqual(lineManager.lineInfo(atRow: 999).lineHeight, 16)
        XCTAssertEqual(lineManager.lineInfo(atRow: 500).lineHeight, 33)
        XCTAssertEqual(lineManager.lineInfo(atRow: 700).lineHeight, 0)
        XCTAssertEqual(typeset.data.lineHeight, 33)
        XCTAssertEqual(lineManager.line(atRow: 1).data.lineHeight, 16)
        XCTAssertEqual(lineManager.contentHeight, 998 * 16 + 33, accuracy: 0.01)
        XCTAssertEqual(lineManager.yPosition(ofRow: 999), 997 * 16 + 33, accuracy: 0.01)
        XCTAssertEqual(lineManager.row(containingYOffset: 501 * 16 + 33 + 1), 502)
    }
}

// MARK: - Lazy row resolution (F07)

extension LineManagerTests {
    /// A tiny deterministic generator, so a failing sequence can be replayed.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Handles are no longer renumbered on every edit; each resolves its row from its line when read.
    /// Whatever the edits do to the tree (leaf splits past 64 lines, leaves emptied and dropped), a held
    /// handle must always name the row its line is on.
    func testHeldHandlesKeepTheirRowsThroughRandomInsertsAndRemovals() {
        var random = SplitMix64(state: 7)
        let lineManager = makeLineManager((0 ..< 1_500).map { "line \($0)" }.joined(separator: "\n"))
        var held = stride(from: 0, to: 1_500, by: 7).map { lineManager.line(atRow: $0) }

        func check(_ step: Int) {
            var rowOfID: [UInt32: Int] = [:]
            for row in 0 ..< lineManager.lineCount { rowOfID[lineManager.lineInfo(atRow: row).id.value] = row }
            for handle in held {
                guard let expected = rowOfID[handle.id.value] else { continue } // its line was removed
                XCTAssertEqual(handle.row, expected, "step \(step): handle \(handle.id.value)")
                XCTAssertTrue(lineManager.line(atRow: expected) === handle, "step \(step): the table still hands out the held handle")
            }
        }

        for step in 0 ..< 400 {
            let row = Int.random(in: 0 ..< lineManager.lineCount, using: &random)
            if Bool.random(using: &random) || lineManager.lineCount < 200 {
                // More than a leaf's worth of lines at a time, so leaves split.
                let count = Int.random(in: 1 ... 150, using: &random)
                _ = lineManager.insert(String(repeating: "new\n", count: count) as NSString, at: lineManager.location(ofRow: row))
            } else {
                let last = min(row + Int.random(in: 1 ... 120, using: &random), lineManager.lineCount - 1)
                let start = lineManager.location(ofRow: row)
                let end = lineManager.location(ofRow: last)
                if end > start { _ = lineManager.removeCharacters(in: NSRange(location: start, length: end - start)) }
            }
            if step % 5 == 0 { check(step) }
            // New handles appear too, as layout asks for lines.
            if step % 11 == 0 { held.append(lineManager.line(atRow: Int.random(in: 0 ..< lineManager.lineCount, using: &random))) }
        }
        check(400)
    }

    /// The point of the change: pasting lines costs the same however many handles are alive.
    func testPastingLinesDoesNotWalkTheLiveHandles() {
        func work(liveHandles: Int) -> Int {
            let lineManager = makeLineManager((0 ..< 10_000).map { "line \($0)" }.joined(separator: "\n"))
            let held = (0 ..< liveHandles).map { lineManager.line(atRow: 200 + $0 * 2) }
            lineManager.resetHandleCounters()
            _ = lineManager.insert(String(repeating: "new\n", count: 500) as NSString, at: lineManager.location(ofRow: 50))
            let pasteWork = lineManager.handleShiftVisits
            // The handles below the paste all moved by 500, and each says so when asked.
            for (offset, handle) in held.enumerated() {
                XCTAssertEqual(handle.row, 700 + offset * 2)
            }
            return pasteWork
        }
        let few = work(liveHandles: 10)
        let many = work(liveHandles: 3_000)
        XCTAssertEqual(many, few, "the work of a paste does not depend on how many handles exist")
        XCTAssertLessThan(many, 4 * 500, "a few row resolutions per pasted line")
    }

    /// A handle read after the manager is gone must not crash: `row` goes through a weak reference.
    func testAHandleOutlivingItsManagerKeepsItsLastRow() {
        var lineManager: LineManager? = makeLineManager("a\nb\nc")
        let handle = lineManager!.line(atRow: 2)
        _ = lineManager!.insert("x\n" as NSString, at: 0)
        XCTAssertEqual(handle.row, 3)
        lineManager = nil
        XCTAssertEqual(handle.row, 3)
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
