import XCTest
@testable import Umbra

/// Alerts under XCTest must answer themselves. `NSAlert.runModal` nests a run loop that nothing
/// in the suite clicks, so a forgotten confirm hangs every test after it.
@MainActor
final class IDEAlertTests: XCTestCase {
    func testAConfirmUnderXCTestDeclinesWithoutAModal() {
        var alert = IDEAlert.confirm(
            "This project's /fix command wants to pre-approve tools for the agent.",
            confirm: "Allow", cancel: "Run Without Them")
        let started = Date()
        XCTAssertFalse(alert.confirms(), "the declining button is the answer when nobody can click")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testADestructiveConfirmUnderXCTestDoesNotConfirm() {
        var alert = IDEAlert.confirm("Delete it?", confirm: "Delete", cancel: "Cancel", isDestructive: true)
        XCTAssertFalse(alert.confirms(), "Return on a destructive alert means no, and so does the test answer")
    }
}
