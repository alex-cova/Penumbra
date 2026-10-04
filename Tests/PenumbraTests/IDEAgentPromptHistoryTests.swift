import Foundation
import XCTest

@testable import Umbra

final class IDEAgentPromptHistoryTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prompts-\(UUID().uuidString)", isDirectory: true)
        file = directory.appendingPathComponent("project/prompts.jsonl")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testPromptsAreKeptTrimmedInOrderWithoutBlanksOrRepeats() {
        let history = IDEAgentPromptHistory(file: nil)
        for text in ["  first  ", "", "   ", "second", "second", "third", "second"] { history.add(text) }
        XCTAssertEqual(history.prompts, ["first", "second", "third", "second"], "only consecutive repeats collapse")
    }

    func testTheHistoryComesBackFromDiskIncludingMultilineAndUnusualText() throws {
        let first = IDEAgentPromptHistory(file: file)
        let tricky = "line one\nline \"two\" with a backslash \\ and émoji ✓\ttab"
        first.add("plain")
        first.add(tricky)

        let second = IDEAgentPromptHistory(file: file)
        XCTAssertEqual(second.prompts, ["plain", tricky])
        second.add("later")
        XCTAssertEqual(IDEAgentPromptHistory(file: file).prompts, ["plain", tricky, "later"])
    }

    func testOnlyTheNewestPromptsStayAndTheFileIsRewrittenSoItDoesNotGrowForever() throws {
        let history = IDEAgentPromptHistory(file: file, limit: 5)
        for index in 1...12 { history.add("prompt \(index)") }
        XCTAssertEqual(history.prompts, (8...12).map { "prompt \($0)" })

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertLessThanOrEqual(lines.count, 5 + 1 + 5 / 5 + 5, "rewritten once it passed the limit by a margin")
        XCTAssertEqual(IDEAgentPromptHistory(file: file, limit: 5).prompts, (8...12).map { "prompt \($0)" })
    }

    func testAHalfWrittenOrForeignLineIsSkipped() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\"good one\"\nnot json at all\n\"unterminated\n42\n\"good two\"\n\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(IDEAgentPromptHistory(file: file).prompts, ["good one", "good two"])
    }

    func testTheFileIsReadableByTheUserAlone() throws {
        let history = IDEAgentPromptHistory(file: file)
        history.add("secret token abc")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
    }

    func testClearingEmptiesBothMemoryAndDisk() {
        let history = IDEAgentPromptHistory(file: file)
        history.add("something")
        history.clear()
        XCTAssertTrue(history.prompts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(IDEAgentPromptHistory(file: file).prompts.isEmpty)
    }

    func testAMissingFileIsAnEmptyHistory() {
        XCTAssertTrue(IDEAgentPromptHistory(file: file).prompts.isEmpty)
    }
}

final class IDEAgentPromptRecallTests: XCTestCase {
    private let prompts = ["one", "two", "three"]

    func testUpWalksBackAndDownWalksForwardToTheDraftTheUserWasTyping() {
        var recall = IDEAgentPromptRecall()
        XCTAssertEqual(recall.previous(current: "half typed", in: prompts), "three")
        XCTAssertEqual(recall.previous(current: "three", in: prompts), "two")
        XCTAssertEqual(recall.previous(current: "two", in: prompts), "one")
        XCTAssertNil(recall.previous(current: "one", in: prompts), "nothing before the oldest")
        XCTAssertEqual(recall.position, 0)

        XCTAssertEqual(recall.next(in: prompts), "two")
        XCTAssertEqual(recall.next(in: prompts), "three")
        XCTAssertEqual(recall.next(in: prompts), "half typed", "past the newest is what was being typed")
        XCTAssertFalse(recall.isRecalling)
        XCTAssertNil(recall.next(in: prompts), "↓ with nothing recalled does nothing")
    }

    func testTheDraftIsKeptFromTheFirstPressOnly() {
        var recall = IDEAgentPromptRecall()
        _ = recall.previous(current: "my draft", in: prompts)
        _ = recall.previous(current: "three", in: prompts)
        _ = recall.next(in: prompts)
        XCTAssertEqual(recall.next(in: prompts), "my draft")
    }

    func testResetMakesTheFieldTheUsersAgain() {
        var recall = IDEAgentPromptRecall()
        _ = recall.previous(current: "draft", in: prompts)
        recall.reset()
        XCTAssertFalse(recall.isRecalling)
        XCTAssertEqual(recall.previous(current: "new draft", in: prompts), "three")
        XCTAssertEqual(recall.next(in: prompts), "new draft", "the draft from before the reset is not the one that comes back")
    }

    func testAnEmptyHistoryHasNothingToRecall() {
        var recall = IDEAgentPromptRecall()
        XCTAssertNil(recall.previous(current: "x", in: []))
        XCTAssertFalse(recall.isRecalling)
    }

    func testSearchIsNewestFirstDeduplicatedAndFuzzy() {
        let all = ["fix the parser", "write docs", "fix the build", "fix the parser", "refactor parser"]
        func match(_ query: String, _ text: String) -> Int? { text.lowercased().contains(query.lowercased()) ? query.count : nil }
        XCTAssertEqual(IDEAgentPromptRecall.search("", in: all, match: match), ["refactor parser", "fix the parser", "fix the build", "write docs"])
        XCTAssertEqual(IDEAgentPromptRecall.search("parser", in: all, match: match), ["refactor parser", "fix the parser"])
        XCTAssertTrue(IDEAgentPromptRecall.search("zzz", in: all, match: match).isEmpty)
        XCTAssertEqual(IDEAgentPromptRecall.search("fix", in: all, match: match, limit: 1), ["fix the parser"])
    }
}
