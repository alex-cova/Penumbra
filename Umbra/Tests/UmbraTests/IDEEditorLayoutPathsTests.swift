import Penumbra
import XCTest
@testable import Umbra

/// Which layout changes keep every pane in place, and so may be animated.
@MainActor
final class IDEEditorLayoutPathsTests: XCTestCase {
    private func pane() -> EditorPane { EditorPane() }

    private func horizontal(_ children: [EditorLayout]) -> EditorLayout {
        .horizontal(EditorSplitData(axis: .horizontal, children: children))
    }

    private func vertical(_ children: [EditorLayout]) -> EditorLayout {
        .vertical(EditorSplitData(axis: .vertical, children: children))
    }

    func testABarePaneIsTheFirstChildOfAChainOfOne() {
        let a = pane()
        XCTAssertEqual(IDEEditorLayoutPaths.paths(of: .pane(a)), [a.id: [0]])
        XCTAssertEqual(IDEEditorLayoutPaths.paths(of: horizontal([.pane(a)])), [a.id: [0]])
    }

    func testOpeningAfterTheLastPaneKeepsEveryPlace() {
        let a = pane(), b = pane(), c = pane()
        XCTAssertTrue(keeps(.pane(a), horizontal([.pane(a), .pane(b)])))
        XCTAssertTrue(keeps(.pane(a), vertical([.pane(a), .pane(b)])))
        XCTAssertTrue(keeps(horizontal([.pane(a), .pane(b)]), horizontal([.pane(a), .pane(b), .pane(c)])))
    }

    func testClosingTheLastPaneKeepsEveryPlace() {
        let a = pane(), b = pane(), c = pane()
        XCTAssertTrue(keeps(horizontal([.pane(a), .pane(b)]), .pane(a)))
        XCTAssertTrue(keeps(horizontal([.pane(a), .pane(b), .pane(c)]), horizontal([.pane(a), .pane(b)])))
    }

    func testOpeningOrClosingBeforeAnotherPaneMovesIt() {
        let a = pane(), b = pane(), c = pane()
        XCTAssertFalse(keeps(.pane(a), horizontal([.pane(b), .pane(a)])), "a opens second")
        XCTAssertFalse(keeps(horizontal([.pane(a), .pane(c)]), horizontal([.pane(a), .pane(b), .pane(c)])), "b opens before c")
        XCTAssertFalse(keeps(horizontal([.pane(a), .pane(b)]), .pane(b)), "closing a moves b to the first place")
    }

    func testNestingInTheOtherDirectionMovesThePane() {
        let a = pane(), b = pane(), c = pane()
        XCTAssertFalse(keeps(
            horizontal([.pane(a), .pane(b)]),
            horizontal([.pane(a), vertical([.pane(b), .pane(c)])])
        ))
    }

    private func keeps(_ before: EditorLayout, _ after: EditorLayout) -> Bool {
        IDEEditorLayoutPaths.keepsPlaces(
            from: IDEEditorLayoutPaths.paths(of: before),
            to: IDEEditorLayoutPaths.paths(of: after)
        )
    }
}
