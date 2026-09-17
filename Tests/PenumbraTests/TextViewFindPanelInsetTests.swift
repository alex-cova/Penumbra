import AppKit
import XCTest
@testable import Penumbra

/// The find bar is now top-anchored (`TextView.layoutSubviews` frames it at `y: 0` instead of
/// `bounds.height - panelHeight`) and pushes text down rather than floating over it, by folding
/// its height into `adjustedContentInset.top`. These exercise that inset plumbing without a live
/// window — see also `FindPanelControllerTests` for the search/replace behavior itself.
@MainActor
final class TextViewFindPanelInsetTests: XCTestCase {
    private func makeTextView(lineCount: Int = 200) -> TextView {
        let text = Array(repeating: "let x = 1", count: lineCount).joined(separator: "\n")
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.layoutIfNeeded()
        return textView
    }

    func testShowingFindPanelAddsItsHeightToAdjustedContentInsetTop() {
        let textView = makeTextView()
        XCTAssertEqual(textView.adjustedContentInset.top, 0)

        textView.showFindPanel()
        XCTAssertGreaterThan(textView.adjustedContentInset.top, 0, "the find bar's intrinsic height should now be reserved at the top")
    }

    func testHidingFindPanelRestoresTheOriginalContentInset() {
        let textView = makeTextView()
        textView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
        XCTAssertEqual(textView.adjustedContentInset.top, 4)

        textView.showFindPanel()
        XCTAssertGreaterThan(textView.adjustedContentInset.top, 4, "the panel's height is added on top of the host's own inset")

        textView.hideFindPanel()
        XCTAssertEqual(textView.adjustedContentInset.top, 4, "hiding must restore exactly the host-configured inset, not zero it out")
    }

    func testShowingFindPanelPushesContentAtRestDownByThePanelHeight() {
        let textView = makeTextView()
        textView.contentOffset = CGPoint(x: 0, y: 0)

        textView.showFindPanel()
        let insetAfterShow = textView.adjustedContentInset.top
        XCTAssertGreaterThan(insetAfterShow, 0)
        // Content translated by exactly the new inset, so the same first line that was visible
        // before the bar opened is still visible, now sitting below the bar instead of under it.
        XCTAssertEqual(textView.contentOffset.y, -insetAfterShow, accuracy: 0.001)
    }

    func testHidingFindPanelReturnsContentOffsetToItsPriorPosition() {
        let textView = makeTextView()
        textView.contentOffset = CGPoint(x: 0, y: 0)

        textView.showFindPanel()
        textView.hideFindPanel()

        XCTAssertEqual(textView.contentOffset.y, 0, accuracy: 0.001)
    }

    /// `FindPanelController` re-notifies `findPanelWillShow(panelHeight:)` with the new height
    /// when its segmented control switches Find ↔ Replace while already showing (see
    /// `FindPanelBarView.onModeChanged` / `FindPanelController.init`). Exercised here by calling
    /// the `FindPanelTarget` hook directly, the way that callback does, rather than through
    /// `TextView.showFindPanel(mode:)` — which only calls it on the initial open.
    func testRepeatedFindPanelWillShowWithATallerHeightShiftsContentByTheDeltaOnly() {
        let textView = makeTextView()
        textView.contentOffset = CGPoint(x: 0, y: 0)

        textView.findPanelWillShow(panelHeight: 52)
        let findInset = textView.adjustedContentInset.top
        let offsetAfterFind = textView.contentOffset.y
        XCTAssertEqual(findInset, 52)
        XCTAssertEqual(offsetAfterFind, -52, accuracy: 0.001)

        textView.findPanelWillShow(panelHeight: 78)
        let replaceInset = textView.adjustedContentInset.top
        XCTAssertEqual(replaceInset, 78)

        let expectedAdditionalShift = replaceInset - findInset
        XCTAssertEqual(
            textView.contentOffset.y,
            offsetAfterFind - expectedAdditionalShift,
            accuracy: 0.001,
            "switching modes while open should translate by exactly the height delta, not re-apply the full new height"
        )
    }

    func testMinimumContentOffsetTracksTheReservedTopInset() {
        let textView = makeTextView()
        XCTAssertEqual(textView.minimumContentOffset.y, 0)

        textView.showFindPanel()
        XCTAssertEqual(textView.minimumContentOffset.y, -textView.adjustedContentInset.top, accuracy: 0.001)
    }

    func testFindPanelViewIsFramedAtTheTopOfTheTextView() {
        let textView = makeTextView()
        textView.showFindPanel()
        textView.layoutIfNeeded()

        guard let panelView = textView.subviews.first(where: { $0 is FindPanelBarView }) else {
            return XCTFail("find panel view should be a direct subview of the TextView")
        }
        XCTAssertEqual(panelView.frame.minY, 0, "the find bar must be anchored at the top, not the bottom")
    }
}
