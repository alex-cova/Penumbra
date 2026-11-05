import Foundation
import Penumbra
import XCTest
@testable import Umbra

/// F-11: the window's large-file session state lives in its own owner, not on `IDEWorkspace`.
/// Tiers, lifts, sniff-once marks and notice-once keys, without opening a window.
@MainActor
final class IDELargeFileStateTests: XCTestCase {
    func testPolicyIsBaseUntilLifted() {
        let state = IDELargeFileState()
        let url = URL(fileURLWithPath: "/tmp/small.swift")
        XCTAssertEqual(state.policy(for: url), state.basePolicy)
        XCTAssertFalse(state.isLifted(url.standardizedFileURL.path))

        state.lift(url.standardizedFileURL.path)
        XCTAssertTrue(state.isLifted(url.standardizedFileURL.path))
        XCTAssertEqual(state.policy(for: url), .disabled)

        state.unlift(url.standardizedFileURL.path)
        XCTAssertFalse(state.isLifted(url.standardizedFileURL.path))
        XCTAssertEqual(state.policy(for: url), state.basePolicy)
    }

    func testLoweredBasePolicyDegradesWithoutALift() {
        let state = IDELargeFileState()
        state.basePolicy = LargeFilePolicy(degradeBytes: 1, readOnlyBytes: 2)
        XCTAssertEqual(state.policy(for: URL(fileURLWithPath: "/tmp/a.swift")), state.basePolicy)
    }

    func testSniffMarksConsumeOnce() {
        let state = IDELargeFileState()
        XCTAssertFalse(state.consumeSniffed("/tmp/a.bin"), "nothing marked, nothing consumed")
        state.markSniffed("/tmp/a.bin")
        XCTAssertTrue(state.consumeSniffed("/tmp/a.bin"))
        XCTAssertFalse(state.consumeSniffed("/tmp/a.bin"), "a second open is not sniffed again")
    }

    func testNoticesPostOncePerKey() {
        let state = IDELargeFileState()
        XCTAssertTrue(state.noticeOnce(key: "swift:/a.swift"))
        XCTAssertFalse(state.noticeOnce(key: "swift:/a.swift"))
        XCTAssertTrue(state.noticeOnce(key: "java:/b.java"), "different sets have their own key")
    }
}
