import Foundation
@testable import Penumbra
import XCTest

@MainActor
final class ScopeHighlightControllerTests: XCTestCase {
    private func region(_ lines: ClosedRange<Int>, depth: Int = 0) -> FoldRegion {
        FoldRegion(depth: depth, lineRange: lines, placeholder: "{...}")
    }

    func testInnermostScopeIsTheSmallestRegionContainingTheRow() {
        let regions = [region(0...40), region(2...20, depth: 1), region(5...9, depth: 2), region(30...35, depth: 1)]
        XCTAssertEqual(ScopeHighlightController.innermostScope(containing: 6, in: regions), 5...9)
        XCTAssertEqual(ScopeHighlightController.innermostScope(containing: 12, in: regions), 2...20)
        XCTAssertEqual(ScopeHighlightController.innermostScope(containing: 32, in: regions), 30...35)
        XCTAssertEqual(ScopeHighlightController.innermostScope(containing: 25, in: regions), 0...40)
        XCTAssertNil(ScopeHighlightController.innermostScope(containing: 41, in: regions))
    }

    func testSingleLineRegionsAreNotAScope() {
        XCTAssertNil(ScopeHighlightController.innermostScope(containing: 3, in: [region(3...3)]))
    }

    func testCaretMovesMarkAndClearTheScope() {
        let controller = ScopeHighlightController()
        controller.debounceInterval = 0
        var applied: [ClosedRange<Int>?] = []
        controller.apply = { applied.append($0) }
        controller.regionsProvider = { [self] in [region(0...10), region(2...5, depth: 1)] }
        controller.rowProvider = { $0 / 10 }
        controller.isEnabled = true

        controller.selectionDidChange(selectedRange: NSRange(location: 30, length: 0), isMultiCaret: false)
        XCTAssertEqual(applied.last ?? nil, 2...5)

        controller.selectionDidChange(selectedRange: NSRange(location: 80, length: 0), isMultiCaret: false)
        XCTAssertEqual(applied.last ?? nil, 0...10)

        controller.selectionDidChange(selectedRange: NSRange(location: 30, length: 0), isMultiCaret: true)
        XCTAssertNil(applied.last ?? nil, "several carets have no single scope")

        controller.isEnabled = false
        XCTAssertNil(applied.last ?? nil)
    }

    func testDisabledControllerAppliesNothing() {
        let controller = ScopeHighlightController()
        controller.debounceInterval = 0
        var calls = 0
        controller.apply = { _ in calls += 1 }
        controller.regionsProvider = { [self] in [region(0...10)] }
        controller.rowProvider = { _ in 1 }
        controller.selectionDidChange(selectedRange: NSRange(location: 3, length: 0), isMultiCaret: false)
        XCTAssertEqual(calls, 0)
    }
}
