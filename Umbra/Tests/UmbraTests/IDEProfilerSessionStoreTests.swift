import Foundation
import XCTest
@testable import Umbra

/// F-11: the profiler tab registry lives in its own owner, not on `IDEWorkspace`.
/// Register, lookup, removal, run-scoped queries and close-all, without a window.
@MainActor
final class IDEProfilerSessionStoreTests: XCTestCase {
    func testRegisterLookupAndRemove() {
        let store = IDEProfilerSessionStore()
        XCTAssertTrue(store.isEmpty)
        let id = UUID()
        XCTAssertNil(store.session(for: id))

        let session = IDEProfilerSession(recordings: [], title: "one")
        store.register(session, for: id)
        XCTAssertFalse(store.isEmpty)
        XCTAssertTrue(store.session(for: id) === session)
        XCTAssertTrue(store.contains(session))
        XCTAssertFalse(store.contains(IDEProfilerSession(recordings: [], title: "other")))

        XCTAssertTrue(store.removeSession(for: id) === session)
        XCTAssertNil(store.session(for: id))
        XCTAssertFalse(store.contains(session))
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.removeSession(for: id), "removing twice answers nil, not a crash")
    }

    func testRunScopedQueries() {
        let store = IDEProfilerSessionStore()
        let runID = UUID().uuidString
        let live = IDEProfilerSession(recordings: [], title: "live", runID: runID)
        let idle = IDEProfilerSession(recordings: [], title: "idle")
        let liveDocument = UUID()
        store.register(live, for: liveDocument)
        store.register(idle, for: UUID())

        // Nothing is live in a unit test (starting a live monitor needs jcmd), so the run
        // queries answer empty — without crashing — and the tab lookup still maps.
        XCTAssertNil(store.liveSession(runID: runID)?.session)
        XCTAssertFalse(store.hasLiveProfile(runID: runID))
        store.failLive(runID: runID, failure: "boom")
        XCTAssertEqual(live.phase, .idle, "failLive touches only live sessions")
        XCTAssertEqual(store.documentID(forSessionID: live.id), liveDocument)
        XCTAssertNil(store.documentID(forSessionID: UUID()))

        let removed = store.closeAll()
        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.allSessions.count, 0)
    }
}
