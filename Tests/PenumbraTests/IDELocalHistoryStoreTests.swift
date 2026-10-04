import Foundation
import XCTest

@testable import Umbra

final class IDELocalHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-history-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func store() -> IDELocalHistoryStore { IDELocalHistoryStore(directory: directory) }
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testARevisionKnowsWhatItWasBeforeAndAfter() async throws {
        let store = store()
        await store.recordBaseline(path: "A.java", text: "v1", at: t0)
        let event = await store.record(path: "A.java", text: "v2", source: .save, at: t0.addingTimeInterval(10))
        let saved = try XCTUnwrap(event)
        let before = await store.text(of: saved, before: true)
        let after = await store.text(of: saved)
        XCTAssertEqual(before, "v1")
        XCTAssertEqual(after, "v2")
        XCTAssertEqual(saved.source, .save)
        XCTAssertEqual(saved.path, "A.java")
    }

    func testAWriteThatKnowsWhatWasThereGivesAFileWithNoHistoryALeftSide() async throws {
        let store = store()
        let event = await store.record(
            path: "A.java", text: "agent's version", source: .agent(tab: "Fix", prompt: "do it"), assumingBefore: "what was on disk", at: t0)
        let written = try XCTUnwrap(event)
        let before = await store.text(of: written, before: true)
        XCTAssertEqual(before, "what was on disk")
        let events = await store.events(forPath: "A.java")
        XCTAssertEqual(events.map(\.source), [.agent(tab: "Fix", prompt: "do it"), .baseline])

        // A file that already has history keeps its own chain.
        await store.record(path: "A.java", text: "later", source: .save, assumingBefore: "ignored", at: t0.addingTimeInterval(5))
        let count = await store.events(forPath: "A.java").count
        XCTAssertEqual(count, 3)
    }

    func testAWriteThatCreatesAFileHasNoBeforeToSeed() async throws {
        let store = store()
        let event = await store.record(path: "New.java", text: "fresh", source: .agent(tab: "T", prompt: "p"), assumingBefore: nil, at: t0)
        XCTAssertNil(try XCTUnwrap(event).before)
        let count = await store.events(forPath: "New.java").count
        XCTAssertEqual(count, 1)
    }

    func testSavingTheSameTextAgainAddsNothing() async {
        let store = store()
        await store.recordBaseline(path: "A.java", text: "same", at: t0)
        let again = await store.record(path: "A.java", text: "same", source: .save, at: t0.addingTimeInterval(5))
        XCTAssertNil(again)
        let count = await store.events(forPath: "A.java").count
        XCTAssertEqual(count, 1)
    }

    func testABaselineIsOnlyTheFirstThingKnown() async {
        let store = store()
        let first = await store.recordBaseline(path: "A.java", text: "one", at: t0)
        let second = await store.recordBaseline(path: "A.java", text: "two", at: t0.addingTimeInterval(1))
        XCTAssertTrue(first)
        XCTAssertFalse(second, "a file with history already has a starting point")
        let events = await store.events(forPath: "A.java")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].source, .baseline)
        XCTAssertNil(events[0].before)
    }

    func testAFirstSaveWithNoBaselineStartsTheChainWithNoBefore() async throws {
        let store = store()
        let event = await store.record(path: "New.java", text: "created", source: .save, at: t0)
        XCTAssertNil(try XCTUnwrap(event).before)
        let hasHistory = await store.hasHistory(forPath: "New.java")
        let other = await store.hasHistory(forPath: "Other.java")
        XCTAssertTrue(hasHistory)
        XCTAssertFalse(other)
    }

    func testEventsComeNewestFirstPerFileAndAcrossFiles() async {
        let store = store()
        await store.record(path: "A", text: "a1", source: .save, at: t0)
        await store.record(path: "B", text: "b1", source: .save, at: t0.addingTimeInterval(1))
        await store.record(path: "A", text: "a2", source: .save, at: t0.addingTimeInterval(2))
        let forA = await store.events(forPath: "A").map(\.time)
        XCTAssertEqual(forA, [t0.addingTimeInterval(2), t0])
        let recent = await store.recentEvents().map(\.path)
        XCTAssertEqual(recent, ["A", "B", "A"])
        let since = await store.recentEvents(since: t0.addingTimeInterval(1)).map(\.path)
        XCTAssertEqual(since, ["A", "B"])
        let limited = await store.recentEvents(limit: 1).map(\.path)
        XCTAssertEqual(limited, ["A"])
    }

    func testADeletionIsAnEventAndARecreationFollowsIt() async throws {
        let store = store()
        await store.record(path: "A", text: "alive", source: .save, at: t0)
        let deleted = await store.record(path: "A", text: nil, source: .external, at: t0.addingTimeInterval(1))
        XCTAssertNil(try XCTUnwrap(deleted).after)
        let again = await store.record(path: "A", text: nil, source: .external, at: t0.addingTimeInterval(2))
        XCTAssertNil(again, "already deleted")
        let back = await store.record(path: "A", text: "alive", source: .revert, at: t0.addingTimeInterval(3))
        XCTAssertNil(try XCTUnwrap(back).before, "it did not exist just before")
        let text = await store.text(of: try XCTUnwrap(back))
        XCTAssertEqual(text, "alive")
    }

    func testTheSameTextIsStoredOnceWhateverFileHasIt() async throws {
        let store = store()
        await store.record(path: "A", text: "shared content", source: .save, at: t0)
        await store.record(path: "B", text: "shared content", source: .save, at: t0)
        let objects = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("objects").path)
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0].count, 64, "named by its SHA-256")
    }

    func testBinaryOversizedAndBuildOutputFilesAreSkipped() async {
        let store = store()
        let binary = await store.record(path: "a.bin", text: "has\u{0}nul", source: .save)
        let huge = await store.record(path: "big.txt", text: String(repeating: "x", count: IDELocalHistoryStore.maxFileBytes + 1), source: .save)
        let git = await store.record(path: ".git/HEAD", text: "ref", source: .save)
        let build = await store.record(path: "app/build/classes/A.class", text: "x", source: .save)
        let nested = await store.record(path: "src/main/java/A.java", text: "ok", source: .save)
        XCTAssertNil(binary)
        XCTAssertNil(huge)
        XCTAssertNil(git)
        XCTAssertNil(build)
        XCTAssertNotNil(nested)
        let justAtLimit = await store.record(path: "limit.txt", text: String(repeating: "x", count: IDELocalHistoryStore.maxFileBytes), source: .save)
        XCTAssertNotNil(justAtLimit)
        let named = await store.record(path: "src/build.gradle", text: "a file called build is fine", source: .save)
        XCTAssertNotNil(named, "only folders named like build output are skipped")
    }

    func testTheHistoryComesBackAfterALaunchAndSurvivesATornLastLine() async throws {
        let first = store()
        await first.record(path: "A", text: "one", source: .save, at: t0)
        await first.record(path: "A", text: "two", source: .agent(tab: "Fix", prompt: "make it two"), group: UUID(), at: t0.addingTimeInterval(1))
        await first.putLabel(path: "A", name: "before refactor", text: "two", at: t0.addingTimeInterval(2))
        let index = directory.appendingPathComponent("index.jsonl")
        let handle = try FileHandle(forWritingTo: index)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\": \"half writt".utf8))
        try handle.close()

        let second = store()
        let events = await second.events(forPath: "A")
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].label, "before refactor")
        XCTAssertEqual(events[1].source, .agent(tab: "Fix", prompt: "make it two"))
        XCTAssertNotNil(events[1].group)
        let text = await second.text(of: events[1])
        XCTAssertEqual(text, "two")
        // The chain continues from what was known: saving "two" again is not news.
        let again = await second.record(path: "A", text: "two", source: .save, at: t0.addingTimeInterval(9))
        XCTAssertNil(again)
    }

    func testALabelPinsTheRevisionEvenWhenNothingChanged() async throws {
        let store = store()
        await store.record(path: "A", text: "v1", source: .save, at: t0)
        let label = await store.putLabel(path: "A", name: "release 1", text: "v1", at: t0.addingTimeInterval(5))
        XCTAssertEqual(try XCTUnwrap(label).label, "release 1")
        XCTAssertEqual(label?.before, label?.after)
        let count = await store.events(forPath: "A").count
        XCTAssertEqual(count, 2)
    }

    // MARK: - Pruning

    func testOldRevisionsGoButNamedOnesStay() async {
        let store = store()
        let day: TimeInterval = 86_400
        await store.record(path: "A", text: "old", source: .save, at: t0)
        await store.putLabel(path: "A", name: "keep me", text: "old", at: t0.addingTimeInterval(1))
        await store.record(path: "A", text: "recent", source: .save, at: t0.addingTimeInterval(10 * day))
        let removed = await store.prune(now: t0.addingTimeInterval(10 * day + 10), maxAge: 7 * day)
        XCTAssertEqual(removed, 1)
        let kept = await store.events(forPath: "A")
        XCTAssertEqual(kept.map(\.label), [nil, "keep me"])
        let text = await store.text(of: kept[1])
        XCTAssertEqual(text, "old", "a named revision keeps its text")
    }

    func testTextsNothingRefersToAreDeletedButSharedOnesStay() async throws {
        let store = store()
        let day: TimeInterval = 86_400
        await store.record(path: "A", text: "only the old one has this", source: .save, at: t0)
        await store.record(path: "B", text: "shared", source: .save, at: t0)
        await store.record(path: "C", text: "shared", source: .save, at: t0.addingTimeInterval(9 * day))
        await store.prune(now: t0.addingTimeInterval(10 * day), maxAge: 7 * day)
        let objects = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("objects").path)
        XCTAssertEqual(objects.count, 1, "the text the surviving event shares is kept, the other is gone")
        let c = await store.events(forPath: "C")
        let text = await store.text(of: c[0])
        XCTAssertEqual(text, "shared")
    }

    func testTheSizeLimitDropsTheOldestUnnamedRevisionsFirst() async throws {
        let store = store()
        for index in 0..<6 {
            let noise = String((0..<3_000).map { _ in Character(UnicodeScalar(UInt8.random(in: 33...126))) })
            await store.record(path: "A\(index)", text: noise, source: .save, at: t0.addingTimeInterval(Double(index)))
        }
        await store.putLabel(path: "A0", name: "pinned", text: "tiny", at: t0.addingTimeInterval(100))
        let before = await store.storedBytes()
        XCTAssertGreaterThan(before, 15_000)
        await store.prune(now: t0.addingTimeInterval(200), maxAge: 365 * 86_400, maxBytes: 9_000)
        let after = await store.storedBytes()
        XCTAssertLessThanOrEqual(after, 9_000 + 100)
        let remaining = await store.recentEvents().map(\.path)
        XCTAssertTrue(remaining.contains("A5"), "the newest survives")
        XCTAssertFalse(remaining.contains("A1"), "the oldest unnamed went first")
        XCTAssertTrue(remaining.contains("A0"), "and the named one stays")
    }

    func testPruningIsPersistedAndNothingToPruneChangesNothing() async {
        let store = store()
        await store.record(path: "A", text: "x", source: .save, at: t0)
        let none = await store.prune(now: t0.addingTimeInterval(60))
        XCTAssertEqual(none, 0)
        await store.prune(now: t0.addingTimeInterval(30 * 86_400))
        let reloaded = IDELocalHistoryStore(directory: directory)
        let events = await reloaded.recentEvents()
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Disk

    func testFilesAreReadableByTheUserAlone() async throws {
        let store = store()
        await store.record(path: "A", text: "private source", source: .save, at: t0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("index.jsonl").path)[.posixPermissions] as? Int, 0o600)
        let object = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("objects").path).first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("objects/\(object)").path)[.posixPermissions] as? Int, 0o600)
    }

    func testClearingForgetsEverythingIncludingOnDisk() async {
        let store = store()
        await store.record(path: "A", text: "x", source: .save, at: t0)
        await store.clear()
        let has = await store.hasHistory(forPath: "A")
        XCTAssertFalse(has)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnicodeAndLineEndingsRoundTrip() async throws {
        let store = store()
        let text = "héllo ✓ 日本語\r\nsecond\n\n  trailing  "
        let event = await store.record(path: "u.txt", text: text, source: .save, at: t0)
        let back = await store.text(of: try XCTUnwrap(event))
        XCTAssertEqual(back, text)
        let empty = await store.record(path: "e.txt", text: "", source: .save, at: t0)
        let emptyBack = await store.text(of: try XCTUnwrap(empty))
        XCTAssertEqual(emptyBack, "", "an empty file is a revision, not a missing one")
    }
}
