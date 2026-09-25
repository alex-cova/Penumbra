@preconcurrency import AppKit
@testable import Penumbra
import XCTest

@MainActor
final class ViewReuseQueueTests: XCTestCase {
    func testDefaultQueueDetachesRecycledViews() {
        let container = NSView()
        let queue = ViewReuseQueue<Int, LineNumberView>()
        let view = queue.dequeueView(forKey: 1)
        container.addSubview(view)
        queue.enqueueViews(withKeys: [1])
        XCTAssertNil(view.superview)
        XCTAssertTrue(queue.dequeueView(forKey: 2) === view)
    }

    /// The gutter keeps recycled line-number views in place, hidden: detaching and re-adding
    /// them was most of its scroll cost.
    func testHidingQueueKeepsRecycledViewsInPlaceAndUnhidesOnReuse() {
        let container = NSView()
        let queue = ViewReuseQueue<Int, LineNumberView>(hidesQueuedViews: true)
        let first = queue.dequeueView(forKey: 1)
        let second = queue.dequeueView(forKey: 2)
        container.addSubview(first)
        container.addSubview(second)

        queue.enqueueViews(withKeys: [1])
        XCTAssertTrue(first.superview === container)
        XCTAssertTrue(first.isHidden)
        XCTAssertNil(queue.visibleViews[1])

        let reused = queue.dequeueView(forKey: 3)
        XCTAssertTrue(reused === first)
        XCTAssertFalse(reused.isHidden)
        XCTAssertTrue(reused.superview === container)
        XCTAssertEqual(container.subviews.count, 2)
    }

    func testHidingQueueDetachesViewsBeyondThePoolCap() {
        let container = NSView()
        let queue = ViewReuseQueue<Int, LineNumberView>(hidesQueuedViews: true)
        let views = (0 ..< 3).map { queue.dequeueView(forKey: $0) }
        views.forEach { container.addSubview($0) }
        // The pool is capped at the visible count before a batch (3 here), so all three fit.
        queue.enqueueViews(withKeys: [0, 1, 2])
        XCTAssertEqual(container.subviews.count, 3)
        XCTAssertTrue(views.allSatisfy(\.isHidden))

        // One view back in use leaves two pooled; recycling it again (cap 1) drops it.
        let reused = queue.dequeueView(forKey: 10)
        XCTAssertFalse(reused.isHidden)
        queue.enqueueViews(withKeys: [10])
        XCTAssertNil(reused.superview, "a view the pool can't take is detached, not left hidden")
        XCTAssertEqual(container.subviews.count, 2)
    }
}
