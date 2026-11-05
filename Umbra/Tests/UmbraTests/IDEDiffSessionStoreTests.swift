import Foundation
import XCTest
@testable import Umbra

/// F-11: the diff/merge session registry lives in its own owner, not on `IDEWorkspace`.
/// Register, lookup, removal and reload-all semantics, without opening a window.
@MainActor
final class IDEDiffSessionStoreTests: XCTestCase {
    private func request(title: String) -> IDEDiffRequest {
        IDEDiffRequest(
            left: IDEDiffSide(source: .text("a"), title: "Left"),
            right: IDEDiffSide(source: .text("b"), title: "Right"),
            filePath: nil,
            title: title
        )
    }

    func testRegisterLookupAndRemove() {
        let store = IDEDiffSessionStore()
        XCTAssertTrue(store.isEmpty)
        let id = UUID()
        XCTAssertNil(store.session(for: id))

        let session = IDEDiffSession(request: request(title: "a (Test)"), siblings: [])
        store.register(session, for: id)
        XCTAssertFalse(store.isEmpty)
        XCTAssertTrue(store.session(for: id) === session)

        XCTAssertTrue(store.removeSession(for: id) === session)
        XCTAssertNil(store.session(for: id))
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.removeSession(for: id), "removing twice answers nil, not a crash")
    }

    func testMergeRegistryIsIndependent() {
        let store = IDEDiffSessionStore()
        let id = UUID()
        let merge = IDEMergeSession(request: IDEMergeRequest(
            path: "/repo/a.txt", relativePath: "a.txt",
            leftTitle: "Yours", rightTitle: "Theirs", tabTitle: "a.txt (Merge)"
        ))
        store.register(merge, for: id)
        XCTAssertFalse(store.isEmpty)
        XCTAssertNil(store.session(for: id), "a merge is not a diff session")
        XCTAssertTrue(store.mergeSession(for: id) === merge)

        let removed = store.removeAll()
        XCTAssertTrue(removed.merges.first === merge)
        XCTAssertTrue(removed.diffs.isEmpty)
        XCTAssertTrue(store.isEmpty)
    }

    func testReloadAllSkipsDirtySessions() async throws {
        let store = IDEDiffSessionStore()
        let clean = IDEDiffSession(request: request(title: "clean"), siblings: [])
        clean.loadContent = { _ in .text("a") }
        let dirty = IDEDiffSession(request: request(title: "dirty"), siblings: [])
        dirty.loadContent = { _ in .text("CHANGED") }
        dirty.currentRightText = { "b" }
        dirty.rightTextDidChange()
        XCTAssertTrue(dirty.isRightDirty)
        store.register(clean, for: UUID())
        store.register(dirty, for: UUID())

        await waitForCondition("the edit lands", timeout: 2) { dirty.right.string == "b" }
        store.reloadAll()
        await waitForCondition("the clean session reloads", timeout: 2) { clean.state == .ready }
        XCTAssertEqual(dirty.right.string, "b", "a dirty session keeps its edited text")
        XCTAssertTrue(dirty.isRightDirty)
    }
}
