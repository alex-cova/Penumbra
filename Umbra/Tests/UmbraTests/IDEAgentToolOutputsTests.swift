import AgentKit
import XCTest
@testable import Umbra

final class IDEAgentToolOutputsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tool-output-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func outputs(_ conversation: UUID = UUID()) -> IDEAgentToolOutputs {
        IDEAgentToolOutputs(directory: directory, conversationID: conversation)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testATextComesBackExactlyAndIsKeptPrivateOnDisk() throws {
        let conversation = UUID()
        let store = outputs(conversation)
        let text = "héllo ✓ 日本語\r\nsecond\n\n  trailing  "
        XCTAssertTrue(store.save(text, id: "out_abc123"))
        XCTAssertEqual(store.load(id: "out_abc123"), text)
        XCTAssertTrue(store.save("", id: "out_empty"))
        XCTAssertEqual(store.load(id: "out_empty"), "", "an empty output is not 'missing'")
        XCTAssertNil(store.load(id: "out_never_saved"))

        let folder = directory.appendingPathComponent(conversation.uuidString)
        XCTAssertEqual(try permissions(folder), 0o700)
        XCTAssertEqual(try permissions(folder.appendingPathComponent("out_abc123")), 0o600)
    }

    func testAnIdThatNamesAPathIsNeitherSavedNorRead() throws {
        let store = outputs()
        XCTAssertFalse(store.save("x", id: "../escape"))
        XCTAssertFalse(store.save("x", id: "a/b"))
        XCTAssertFalse(store.save("x", id: ""))
        XCTAssertNil(store.load(id: "../escape"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    func testAnotherConversationOfTheProjectCanReadWhatAForkInheritedAPointerTo() {
        let first = outputs()
        XCTAssertTrue(first.save("kept", id: "out_one"))
        XCTAssertEqual(outputs().load(id: "out_one"), "kept")
    }

    func testRemovingAConversationLeavesTheOthers() {
        let first = outputs(), second = outputs()
        _ = first.save("a", id: "out_a")
        _ = second.save("b", id: "out_b")
        first.removeConversation()
        XCTAssertNil(first.load(id: "out_a"))
        XCTAssertEqual(second.load(id: "out_b"), "b")
        second.removeAll()
        XCTAssertNil(second.load(id: "out_b"))
    }

    private func age(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
    }

    func testTheSweepDropsWhatIsOlderThanAWeekAndTheEmptyFolderWithIt() throws {
        let old = outputs(), fresh = outputs()
        _ = old.save("old", id: "out_old")
        _ = fresh.save("fresh", id: "out_new")
        try age(directory.appendingPathComponent(old.conversationID.uuidString).appendingPathComponent("out_old"), days: 8)

        XCTAssertEqual(IDEAgentToolOutputs.sweep(directory: directory), 1)
        XCTAssertNil(old.load(id: "out_old"))
        XCTAssertEqual(fresh.load(id: "out_new"), "fresh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(old.conversationID.uuidString).path))
    }

    func testTheSweepKeepsTheProjectUnderItsLimitByDroppingTheOldestFirst() throws {
        let store = outputs()
        // Random text does not compress, so the sizes on disk are close to the sizes written.
        func noise() -> String { String((0..<4_000).map { _ in Character(UnicodeScalar(UInt8.random(in: 33...126))) }) }
        for (index, days) in [3.0, 2.0, 1.0].enumerated() {
            _ = store.save(noise(), id: "out_\(index)")
            try age(directory.appendingPathComponent(store.conversationID.uuidString).appendingPathComponent("out_\(index)"), days: days)
        }
        IDEAgentToolOutputs.sweep(directory: directory, limit: 9_000)
        XCTAssertNil(store.load(id: "out_0"), "the oldest goes first")
        XCTAssertNotNil(store.load(id: "out_1"))
        XCTAssertNotNil(store.load(id: "out_2"))
    }

    func testSweepingAFolderThatDoesNotExistIsHarmless() {
        XCTAssertEqual(IDEAgentToolOutputs.sweep(directory: directory.appendingPathComponent("nothing")), 0)
    }
}
