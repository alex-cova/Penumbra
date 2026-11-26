import XCTest
@testable import Umbra

/// Reselecting an already-open tab must not reopen its collapsed package unless
/// "Reveal Reselected Files" is on. The first activation (a fresh open) always reveals.
@MainActor
final class IDEExplorerAutoRevealTests: XCTestCase {
    func testFirstActivationReveals() {
        let model = IDEProjectModel()
        let id = UUID()
        XCTAssertTrue(model.shouldAutoReveal(documentID: id, revealReselected: false))
    }

    func testReselectDoesNotRevealByDefault() {
        let model = IDEProjectModel()
        let id = UUID()
        XCTAssertTrue(model.shouldAutoReveal(documentID: id, revealReselected: false))
        XCTAssertFalse(model.shouldAutoReveal(documentID: id, revealReselected: false))
        // A third activation stays quiet too.
        XCTAssertFalse(model.shouldAutoReveal(documentID: id, revealReselected: false))
    }

    func testReselectRevealsWhenEnabled() {
        let model = IDEProjectModel()
        let id = UUID()
        XCTAssertTrue(model.shouldAutoReveal(documentID: id, revealReselected: true))
        XCTAssertTrue(model.shouldAutoReveal(documentID: id, revealReselected: true))
    }

    func testOtherDocumentsAreIndependent() {
        let model = IDEProjectModel()
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(model.shouldAutoReveal(documentID: first, revealReselected: false))
        XCTAssertTrue(model.shouldAutoReveal(documentID: second, revealReselected: false))
        XCTAssertFalse(model.shouldAutoReveal(documentID: first, revealReselected: false))
    }

    func testClosingForgetsSoReopeningReveals() {
        let model = IDEProjectModel()
        let id = UUID()
        XCTAssertTrue(model.shouldAutoReveal(documentID: id, revealReselected: false))
        XCTAssertFalse(model.shouldAutoReveal(documentID: id, revealReselected: false))
        model.forgetAutoRevealed(documentID: id)
        XCTAssertTrue(model.shouldAutoReveal(documentID: id, revealReselected: false))
    }

    func testSetRootForgetsSoSwitchingFoldersReveals() {
        let model = IDEProjectModel()
        let id = UUID()
        XCTAssertTrue(model.shouldAutoReveal(documentID: id, revealReselected: false))
        model.setRoot(nil)
        XCTAssertTrue(model.shouldAutoReveal(documentID: id, revealReselected: false))
    }
}
