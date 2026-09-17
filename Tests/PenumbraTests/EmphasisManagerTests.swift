import Foundation
@testable import Penumbra
import XCTest

final class EmphasisManagerTests: XCTestCase {
    func testGroupedEmphasesMergeWithUserRanges() {
        let lineManager = LineManager(stringView: StringView(string: "abc"))
        let highlightService = HighlightService(lineManager: lineManager)
        let manager = EmphasisManager()
        manager.highlightService = highlightService
        let userRange = HighlightedRange(range: NSRange(location: 0, length: 1), color: .red)
        manager.userHighlightedRanges = [userRange]
        manager.addEmphasis(Emphasis(range: NSRange(location: 1, length: 1), style: .underline(color: .blue)),
                              for: EmphasisGroup.find,
                              color: .blue)
        XCTAssertEqual(highlightService.highlightedRanges.count, 2)
        manager.removeEmphases(for: EmphasisGroup.find)
        XCTAssertEqual(highlightService.highlightedRanges, [userRange])
    }

    func testFlashEmphasisIsRemovedAutomatically() async {
        let lineManager = LineManager(stringView: StringView(string: "abc"))
        let highlightService = HighlightService(lineManager: lineManager)
        let manager = EmphasisManager()
        manager.highlightService = highlightService
        let expectation = expectation(description: "flash removed")
        manager.onEmphasesChanged = {
            if highlightService.highlightedRanges.isEmpty {
                expectation.fulfill()
            }
        }
        manager.addEmphasis(Emphasis(range: NSRange(location: 0, length: 1), style: .standard, flash: true),
                              for: EmphasisGroup.brackets,
                              color: .yellow)
        XCTAssertEqual(highlightService.highlightedRanges.count, 1)
        await fulfillment(of: [expectation], timeout: 1.5)
    }
}

final class BracketMatchingControllerTests: XCTestCase {
    func testFindClosingPairSkipsNestedBrackets() {
        let stringView = StringView(string: "{ { } }")
        let controller = BracketMatchingController(stringView: stringView)
        struct Pair: CharacterPair {
            let leading = "{"
            let trailing = "}"
        }
        controller.characterPairs = [Pair()]
        let match = controller.findClosingPairForTesting(close: "{", open: "}", from: 1, limit: stringView.string.length, reverse: false)
        XCTAssertEqual(match, 6)
    }
}

private extension BracketMatchingController {
    func findClosingPairForTesting(close: String, open: String, from: Int, limit: Int, reverse: Bool) -> Int? {
        var options: NSString.EnumerationOptions = .byComposedCharacterSequences
        if reverse {
            options.insert(.reverse)
        }
        let searchRange = reverse
            ? NSRange(location: limit, length: from - limit + 1)
            : NSRange(location: from, length: limit - from)
        guard searchRange.length > 0 else {
            return nil
        }
        var closeCount = 0
        var matchLocation: Int?
        stringView.string.enumerateSubstrings(in: searchRange, options: options) { substring, range, _, stop in
            if substring == close {
                closeCount += 1
            } else if substring == open {
                closeCount -= 1
            }
            if closeCount < 0 {
                matchLocation = range.location
                stop.pointee = true
            }
        }
        return matchLocation
    }
}
