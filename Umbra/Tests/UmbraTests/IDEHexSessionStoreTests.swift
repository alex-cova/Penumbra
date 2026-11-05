import Foundation
import HexKit
import XCTest
@testable import Umbra

/// F-11: the hex tab registry lives in its own owner, not on `IDEWorkspace`.
/// Register, lookup, removal and close-all, without opening a window.
@MainActor
final class IDEHexSessionStoreTests: XCTestCase {
    private func makeSession() -> IDEHexSession {
        IDEHexSession(documentID: UUID(), document: HexDocument(bytes: [0x41, 0x42]), fileURL: nil)
    }

    func testRegisterLookupAndRemove() {
        let store = IDEHexSessionStore()
        XCTAssertTrue(store.isEmpty)
        let id = UUID()
        XCTAssertNil(store.session(for: id))

        let session = makeSession()
        store.register(session, for: id)
        XCTAssertFalse(store.isEmpty)
        XCTAssertTrue(store.session(for: id) === session)

        XCTAssertTrue(store.removeSession(for: id) === session)
        XCTAssertNil(store.session(for: id))
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.removeSession(for: id), "removing twice answers nil, not a crash")
    }

    func testCloseAllClosesAndEmpties() {
        let store = IDEHexSessionStore()
        let first = makeSession()
        let second = makeSession()
        store.register(first, for: UUID())
        store.register(second, for: UUID())

        let removed = store.closeAll()
        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(store.closeAll().isEmpty)
    }
}
