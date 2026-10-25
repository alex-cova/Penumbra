import Foundation
import XCTest
@testable import JavaIntelligence
@testable import Umbra

/// The trust question shared by the five project systems: one gate, one recording rule. Each
/// case pins a row of the matrix (fast path, missing prompt, yes/no, stale generation) so a
/// later edit cannot silently change what is remembered.
@MainActor
final class IDEProjectTrustGateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IDEProjectTrustGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> ProjectTrustStore {
        ProjectTrustStore(storeURL: directory.appendingPathComponent("trust.json"))
    }

    private func project(_ name: String) -> URL {
        URL(fileURLWithPath: "/work/\(name)", isDirectory: true)
    }

    func testAlreadyTrustedNeverPrompts() async {
        let store = store()
        let root = project("alpha")
        store.setTrusted(true, for: root)
        var prompted = false
        let gate = IDEProjectTrustGate(store: store, prompt: { _ in prompted = true; return true })

        let confirmed = await gate.confirmTrust(for: root)
        XCTAssertTrue(confirmed)
        XCTAssertFalse(prompted)
    }

    func testMissingPromptDeniesWithoutRecording() async {
        let store = store()
        let root = project("alpha")
        let gate = IDEProjectTrustGate(store: store, prompt: nil)

        let denied = await gate.confirmTrust(for: root)
        XCTAssertFalse(denied)
        XCTAssertNil(store.decision(for: root))
    }

    func testMissingPromptRecordsDeclineForReloadFlows() async {
        let store = store()
        let root = project("alpha")
        let gate = IDEProjectTrustGate(store: store, prompt: nil)

        let denied = await gate.confirmTrust(for: root, recordDeclined: true)
        XCTAssertFalse(denied)
        XCTAssertEqual(store.decision(for: root), false)
    }

    func testYesIsRemembered() async {
        let store = store()
        let root = project("alpha")
        let gate = IDEProjectTrustGate(store: store, prompt: { _ in true })

        let confirmed = await gate.confirmTrust(for: root)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(store.decision(for: root), true)
    }

    func testNoIsForgottenForRunFlows() async {
        let store = store()
        let root = project("alpha")
        let gate = IDEProjectTrustGate(store: store, prompt: { _ in false })

        let denied = await gate.confirmTrust(for: root)
        XCTAssertFalse(denied)
        XCTAssertNil(store.decision(for: root))
    }

    func testNoIsRememberedForReloadFlows() async {
        let store = store()
        let root = project("alpha")
        let gate = IDEProjectTrustGate(store: store, prompt: { _ in false })

        let denied = await gate.confirmTrust(for: root, recordDeclined: true)
        XCTAssertFalse(denied)
        XCTAssertEqual(store.decision(for: root), false)
    }

    func testStaleGenerationRecordsNothing() async {
        let store = store()
        let root = project("alpha")
        let gate = IDEProjectTrustGate(store: store, prompt: { _ in true })

        let denied = await gate.confirmTrust(for: root, recordDeclined: true, isCurrent: { false })
        XCTAssertFalse(denied)
        XCTAssertNil(store.decision(for: root))
    }

    func testFreshGenerationKeepsTheAnswer() async {
        let store = store()
        let root = project("alpha")
        let gate = IDEProjectTrustGate(store: store, prompt: { _ in true })

        let confirmed = await gate.confirmTrust(for: root, recordDeclined: true, isCurrent: { true })
        XCTAssertTrue(confirmed)
        XCTAssertEqual(store.decision(for: root), true)
    }
}
