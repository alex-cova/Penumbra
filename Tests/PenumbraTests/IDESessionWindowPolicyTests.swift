import Foundation
import XCTest
@testable import Umbra

/// The rules behind `IDEWindowRegistry`'s session window, hand-over and restore decisions.
final class IDESessionWindowPolicyTests: XCTestCase {
    private typealias Policy = IDESessionWindowPolicy
    private let a = UUID(), b = UUID(), c = UUID()

    private func window(_ id: UUID, pristine: Bool = false) -> Policy.Window {
        Policy.Window(id: id, isPristine: pristine)
    }

    // MARK: - Session window

    func testTheMostRecentlyKeyWindowWithContentIsTheSessionWindow() {
        XCTAssertEqual(Policy.sessionWindow(in: [window(a), window(b)]), a)
    }

    func testABlankWindowNextToOthersNeverBecomesTheSessionWindowEvenWhenKey() {
        XCTAssertEqual(Policy.sessionWindow(in: [window(a, pristine: true), window(b)]), b)
    }

    func testUsingABlankWindowMakesItTheSessionWindowWhenItIsKey() {
        // The folder opened in it made it non-pristine.
        XCTAssertEqual(Policy.sessionWindow(in: [window(a, pristine: false), window(b)]), a)
    }

    func testNoSessionWindowWhenEveryWindowIsBlankOrThereAreNone() {
        XCTAssertNil(Policy.sessionWindow(in: [window(a, pristine: true)]))
        XCTAssertNil(Policy.sessionWindow(in: []))
    }

    // MARK: - Hand-over

    func testClosingTheSessionWindowHandsOverToTheNextKeyWindowWithContent() {
        let windows = [window(a), window(b, pristine: true), window(c)]
        XCTAssertEqual(Policy.successor(afterClosing: a, in: windows), c)
    }

    func testNobodyTakesOverWhenOnlyBlankWindowsRemain() {
        let windows = [window(a), window(b, pristine: true)]
        XCTAssertNil(Policy.successor(afterClosing: a, in: windows))
    }

    func testClosingABackgroundWindowChangesNothing() {
        let windows = [window(a), window(b), window(c)]
        XCTAssertNil(Policy.successor(afterClosing: b, in: windows))
        XCTAssertNil(Policy.successor(afterClosing: c, in: windows))
    }

    func testClosingABlankWindowChangesNothing() {
        let windows = [window(a, pristine: true), window(b)]
        XCTAssertNil(Policy.successor(afterClosing: a, in: windows))
    }

    func testClosingAnUnknownWindowChangesNothing() {
        XCTAssertNil(Policy.successor(afterClosing: c, in: [window(a), window(b)]))
    }

    // MARK: - Restore

    func testRestoresOnlyWithNoWindowAndNoPendingOpen() {
        XCTAssertTrue(Policy.shouldRestoreLastWindow(openWindowCount: 0, pendingNewWindowJobs: 0))
        XCTAssertFalse(Policy.shouldRestoreLastWindow(openWindowCount: 1, pendingNewWindowJobs: 0))
        XCTAssertFalse(Policy.shouldRestoreLastWindow(openWindowCount: 0, pendingNewWindowJobs: 1))
    }

    // MARK: - Ordering

    func testActivatingARegisteredWindowMovesItToTheFront() {
        XCTAssertEqual(Policy.activated(c, in: [a, b, c]), [c, a, b])
    }

    func testActivatingAnUnregisteredWindowIsIgnored() {
        // It becomes key before its workspace finishes bootstrapping; adding it here would make
        // `register` skip it and count it as open while it still decides whether to restore.
        XCTAssertEqual(Policy.activated(c, in: [a, b]), [a, b])
    }

    func testAKeyWindowRegistersAtTheFrontAndAnotherAtTheBack() {
        XCTAssertEqual(Policy.registered(c, isKey: true, in: [a, b]), [c, a, b])
        XCTAssertEqual(Policy.registered(c, isKey: false, in: [a, b]), [a, b, c])
    }

    func testRegisteringTwiceKeepsTheOrder() {
        XCTAssertEqual(Policy.registered(a, isKey: true, in: [b, a]), [b, a])
    }
}
