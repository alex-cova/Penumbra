import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

final class IDEDiffComputerTests: XCTestCase {
    private func chunks(
        _ left: String,
        _ right: String,
        whitespace: IDEDiffWhitespacePolicy = .none,
        highlight: IDEDiffHighlightMode = .words
    ) -> [IDEDiffChunk] {
        IDEDiffComputer.chunks(left: IDEDiffText(left), right: IDEDiffText(right), whitespace: whitespace, highlight: highlight)
    }

    private func fragments(_ text: String, _ ranges: [NSRange]) -> [String] {
        ranges.map { (text as NSString).substring(with: $0) }
    }

    // MARK: - Lines

    func testLinesCountLikeTheEditor() {
        XCTAssertEqual(IDEDiffText("").lineCount, 1)
        XCTAssertEqual(IDEDiffText("a\nb\n").lineCount, 3)
        let crlf = IDEDiffText("a\r\nbc\r\n")
        XCTAssertEqual(crlf.lineCount, 3)
        XCTAssertEqual(crlf.line(1), "bc")
        XCTAssertEqual(crlf.range(ofLines: 1 ..< 2), NSRange(location: 3, length: 4))
        XCTAssertEqual(crlf.lineIndex(containing: 4), 1)
    }

    func testIdenticalTextsHaveNoChunks() {
        XCTAssertTrue(chunks("a\nb\n", "a\nb\n").isEmpty)
        XCTAssertTrue(chunks("", "").isEmpty)
    }

    func testInsertDeleteAndModify() {
        let result = chunks("a\nb\nc\nd\n", "a\nB\nc\nd\ne\n")
        XCTAssertEqual(result.map(\.left), [1 ..< 2, 4 ..< 4])
        XCTAssertEqual(result.map(\.right), [1 ..< 2, 4 ..< 5])
        XCTAssertEqual(result.map(\.kind), [.modified, .inserted])

        let deleted = chunks("a\nb\nc", "a\nc")
        XCTAssertEqual(deleted.map(\.left), [1 ..< 2])
        XCTAssertEqual(deleted.map(\.right), [1 ..< 1])
        XCTAssertEqual(deleted.first?.kind, .deleted)
    }

    func testEverythingAgainstAnEmptySide() {
        // The editor's empty last line matches the empty side's only line.
        let added = chunks("", "x\ny\n")
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0].right, 0 ..< 2)
    }

    // MARK: - Whitespace

    func testWhitespacePolicies() {
        let left = "if (a) {\n  call();\n}\n"
        let right = "if (a) {\n    call( );\n\n}\n"
        XCTAssertEqual(chunks(left, right, whitespace: .none).map(\.right), [1 ..< 3])
        // Trim ignores the indent but not the space inside the parentheses.
        XCTAssertEqual(chunks(left, right, whitespace: .trim).map(\.right), [1 ..< 3])
        // Ignoring all whitespace leaves the new empty line.
        XCTAssertEqual(chunks(left, right, whitespace: .ignoreAll).map(\.right), [2 ..< 3])
        XCTAssertTrue(chunks(left, right, whitespace: .ignoreAllAndEmptyLines).isEmpty)
    }

    func testLineEndingsAloneAreNotChanges() {
        XCTAssertTrue(chunks("a\r\nb\r\n", "a\nb\n").isEmpty)
    }

    // MARK: - Inside a line

    func testWordFragments() {
        let left = "let total = price * count\n"
        let right = "let total = cost * count + tax\n"
        let chunk = chunks(left, right).first
        XCTAssertEqual(fragments(left, chunk?.leftFragments ?? []), ["price"])
        XCTAssertEqual(fragments(right, chunk?.rightFragments ?? []), ["cost", "+ tax"])
    }

    func testCharacterFragments() {
        let chunk = chunks("color\n", "colour\n", highlight: .chars).first
        XCTAssertEqual(chunk?.leftFragments, [])
        XCTAssertEqual(fragments("colour\n", chunk?.rightFragments ?? []), ["u"])
    }

    func testLinesModeAndUnrelatedLinesHaveNoFragments() {
        XCTAssertEqual(chunks("a b\n", "a c\n", highlight: .lines).first?.rightFragments, [])
        XCTAssertEqual(chunks("alpha\n", "beta\n").first?.rightFragments, [])
    }

    func testSplitModeMakesOneChunkPerLine() {
        let left = "one = 1\ntwo = 2\n"
        let right = "one = 10\ntwo = 20\n"
        XCTAssertEqual(chunks(left, right, highlight: .words).count, 1)
        let split = chunks(left, right, highlight: .split)
        XCTAssertEqual(split.map(\.left), [0 ..< 1, 1 ..< 2])
        XCTAssertEqual(fragments(right, split[1].rightFragments), ["20"])
    }

    func testIgnoredWhitespaceIsNotHighlighted() {
        let chunk = chunks("f(a,b) + x\n", "f(a, b) + y\n", whitespace: .ignoreAll).first
        XCTAssertEqual(fragments("f(a, b) + y\n", chunk?.rightFragments ?? []), ["y"])
    }

    // MARK: - Unified

    func testUnifiedLayoutInterleavesDeletedThenInsertedLines() {
        let left = IDEDiffText("a\nold value\nc\n")
        let right = IDEDiffText("a\nnew value\nc\nd\n")
        let result = IDEDiffComputer.chunks(left: left, right: right, whitespace: .none, highlight: .words)
        let layout = IDEDiffUnifiedLayout(left: left, right: right, chunks: result)
        XCTAssertEqual(layout.text, "a\nold value\nnew value\nc\nd\n")
        XCTAssertEqual(layout.kinds, [.unchanged, .deleted, .inserted, .unchanged, .inserted, .unchanged])
        XCTAssertEqual(layout.oldNumbers, [1, 2, nil, 3, nil, 4])
        XCTAssertEqual(layout.newNumbers, [1, nil, 2, 3, 4, 5])
        XCTAssertEqual(layout.chunkRows.map(\.all), [1 ..< 3, 4 ..< 5])
        XCTAssertEqual(fragments(layout.text, layout.deletedFragments), ["old"])
        XCTAssertEqual(fragments(layout.text, layout.insertedFragments), ["new"])
    }

    // MARK: - Requests

    func testIndexActions() {
        let unstaged = IDEDiffRequest.change(path: "/r/a.txt", relativePath: "a.txt", staged: false, isNew: false)
        XCTAssertEqual(unstaged.indexAction, .stage)
        XCTAssertTrue(unstaged.isRightEditable)
        let staged = IDEDiffRequest.change(path: "/r/a.txt", relativePath: "a.txt", staged: true, isNew: false)
        XCTAssertEqual(staged.indexAction, .unstage)
        XCTAssertFalse(staged.isRightEditable)
        XCTAssertNotEqual(unstaged.id, staged.id)
        let untracked = IDEDiffRequest.change(path: "/r/n.txt", relativePath: "n.txt", staged: false, isNew: true)
        XCTAssertNil(untracked.indexAction)
        XCTAssertEqual(untracked.repositoryRelativePath, nil)
    }
}

final class IDEDiffPatchBuilderTests: XCTestCase {
    private func patch(_ left: String, _ right: String, chunk index: Int = 0) -> String? {
        let l = IDEDiffText(left)
        let r = IDEDiffText(right)
        let chunks = IDEDiffComputer.chunks(left: l, right: r, whitespace: .none, highlight: .lines)
        return IDEDiffPatchBuilder.patch(for: chunks[index], left: l, right: r, path: "a.txt")
    }

    private let header = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n"

    func testHeadersUseZeroContextCounts() {
        XCTAssertEqual(patch("1\n2\n3\n", "1\nTWO\n3\n"), header + "@@ -2,1 +2,1 @@\n-2\n+TWO\n")
        XCTAssertEqual(patch("1\n3\n", "1\n2\n3\n"), header + "@@ -1,0 +2,1 @@\n+2\n")
        XCTAssertEqual(patch("1\n2\n3\n", "1\n3\n"), header + "@@ -2,1 +1,0 @@\n-2\n")
    }

    func testMissingFinalLineBreak() {
        XCTAssertEqual(patch("a\nb", "a\nc"),
                       header + "@@ -2,1 +2,1 @@\n-b\n\\ No newline at end of file\n+c\n\\ No newline at end of file\n")
        // Appending after an unterminated last line rewrites that line as well.
        XCTAssertEqual(patch("a\nb", "a\nb\nc\n"),
                       header + "@@ -2,1 +2,2 @@\n-b\n\\ No newline at end of file\n+b\n+c\n")
    }

    func testOnlyTheEditorsEmptyLastLineIsNotAPatch() {
        XCTAssertNil(patch("a", "a\n"))
    }

    func testCRLFLinesKeepTheirLineBreaks() {
        XCTAssertEqual(patch("1\r\n2\r\n", "1\r\nx\r\n"), header + "@@ -2,1 +2,1 @@\n-2\r\n+x\r\n")
    }

    func testPatchesApplyWithGit() async throws {
        let runner = SystemGitRunner()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diff-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await runner.run(["init", "-q"], in: directory)
        let cases: [(String, String)] = [
            ("1\n2\n3\n4\n5\n", "0\n1\nTWO\n3\n5\n6\n"),
            ("a\nb", "a\nb\nc\n"),
            ("x\r\ny\r\n", "x\r\nz\r\nw\r\n"),
        ]
        for (left, right) in cases {
            let l = IDEDiffText(left)
            let r = IDEDiffText(right)
            let chunks = IDEDiffComputer.chunks(left: l, right: r, whitespace: .none, highlight: .lines)
            // Apply the hunks bottom-up, each to the result of the one below it.
            var current = left
            for chunk in chunks.reversed() {
                guard let patch = IDEDiffPatchBuilder.patch(for: chunk, left: IDEDiffText(current), right: r, path: "a.txt") else { continue }
                try current.write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
                _ = try await runner.run(["apply", "--unidiff-zero", "--whitespace=nowarn", "-"], in: directory, stdin: Data(patch.utf8), environment: nil)
                current = try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8)
            }
            XCTAssertEqual(current, right, "\(left.debugDescription) → \(right.debugDescription)")
        }
    }
}
