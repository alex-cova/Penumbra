import AppKit
import XCTest
@testable import Penumbra

@MainActor
final class EditorHostContainerTests: XCTestCase {
    func testMountingTwiceKeepsTheHostInPlace() {
        let container = EditorHostContainer(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let host = NSView()
        container.mount(host)
        container.mount(host)
        XCTAssertTrue(host.superview === container)
        XCTAssertEqual(container.subviews.count, 1)
    }

    func testNewerContainerTakesTheHostFromAnOlderOne() {
        let old = EditorHostContainer(frame: .zero)
        let host = NSView()
        old.mount(host)
        let new = EditorHostContainer(frame: .zero)
        new.mount(host)
        XCTAssertTrue(host.superview === new)
    }

    /// Closing a split: SwiftUI makes the replacement container first, then still refreshes the
    /// outgoing one. The outgoing container must not pull the host back into itself.
    func testOlderContainerDoesNotStealTheHostBack() {
        let old = EditorHostContainer(frame: .zero)
        let host = NSView()
        old.mount(host)
        let new = EditorHostContainer(frame: .zero)
        new.mount(host)

        old.mount(host)

        XCTAssertTrue(host.superview === new)
    }

    func testHostCanBeMountedAgainWhenItsOwnerIsGone() {
        let host = NSView()
        var owner: EditorHostContainer? = EditorHostContainer(frame: .zero)
        owner?.mount(host)
        owner = nil
        host.removeFromSuperview()

        let replacement = EditorHostContainer(frame: .zero)
        replacement.mount(host)
        XCTAssertTrue(host.superview === replacement)
    }
}
