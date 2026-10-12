import Foundation
import XCTest
@testable import Umbra

final class IDEMergeComputerTests: XCTestCase {
    private func chunks(_ base: String, _ left: String, _ right: String) -> [IDEMergeChunk] {
        IDEMergeComputer.chunks(base: IDEDiffText(base), left: IDEDiffText(left), right: IDEDiffText(right))
    }

    private func merged(_ base: String, _ left: String, _ right: String, conflict: IDEMergeResolution = .base) -> String {
        let b = IDEDiffText(base), l = IDEDiffText(left), r = IDEDiffText(right)
        return IDEMergeComputer.merged(
            base: b, left: l, right: r, chunks: IDEMergeComputer.chunks(base: b, left: l, right: r), conflict: conflict)
    }

    private func kinds(_ chunks: [IDEMergeChunk]) -> [IDEMergeChunk.Kind] {
        chunks.filter(\.isChange).map(\.kind)
    }

    func testIdenticalTextsAreOneUnchangedRegion() {
        let result = chunks("a\nb\n", "a\nb\n", "a\nb\n")
        XCTAssertEqual(result.map(\.kind), [.unchanged])
        XCTAssertEqual(merged("a\nb\n", "a\nb\n", "a\nb\n"), "a\nb\n")
    }

    func testChangesInDifferentPlacesAreBothApplied() {
        let base = "1\n2\n3\n4\n5\n"
        let left = "1\nL\n3\n4\n5\n"
        let right = "1\n2\n3\n4\nR\n"
        XCTAssertEqual(kinds(chunks(base, left, right)), [.leftOnly, .rightOnly])
        XCTAssertEqual(merged(base, left, right), "1\nL\n3\n4\nR\n")
    }

    func testTheSameChangeOnBothSidesIsNotAConflict() {
        let result = chunks("a\nb\nc\n", "a\nX\nc\n", "a\nX\nc\n")
        XCTAssertEqual(kinds(result), [.bothSame])
        XCTAssertEqual(merged("a\nb\nc\n", "a\nX\nc\n", "a\nX\nc\n"), "a\nX\nc\n")
    }

    func testDifferentChangesToTheSameLineConflict() {
        let result = chunks("a\nb\nc\n", "a\nL\nc\n", "a\nR\nc\n")
        XCTAssertEqual(kinds(result), [.conflict])
        XCTAssertEqual(IDEMergeComputer.conflictCount(result), 1)
        XCTAssertEqual(merged("a\nb\nc\n", "a\nL\nc\n", "a\nR\nc\n", conflict: .base), "a\nb\nc\n")
        XCTAssertEqual(merged("a\nb\nc\n", "a\nL\nc\n", "a\nR\nc\n", conflict: .left), "a\nL\nc\n")
        XCTAssertEqual(merged("a\nb\nc\n", "a\nL\nc\n", "a\nR\nc\n", conflict: .right), "a\nR\nc\n")
        XCTAssertEqual(merged("a\nb\nc\n", "a\nL\nc\n", "a\nR\nc\n", conflict: .both), "a\nL\nR\nc\n")
    }

    func testAdjacentEditsConflictAsGitDoes() {
        // Line 2 on the left, line 3 on the right: touching regions are one conflict.
        let result = chunks("1\n2\n3\n4\n", "1\nL\n3\n4\n", "1\n2\nR\n4\n")
        XCTAssertEqual(kinds(result), [.conflict])
    }

    func testEditsOneLineApartDoNotConflict() {
        let result = chunks("1\n2\n3\n4\n5\n", "1\nL\n3\n4\n5\n", "1\n2\n3\nR\n5\n")
        XCTAssertEqual(kinds(result), [.leftOnly, .rightOnly])
        XCTAssertEqual(merged("1\n2\n3\n4\n5\n", "1\nL\n3\n4\n5\n", "1\n2\n3\nR\n5\n"), "1\nL\n3\nR\n5\n")
    }

    func testOneSideDeletesWhatTheOtherModifiesIsAConflict() {
        let result = chunks("a\nb\nc\n", "a\nc\n", "a\nB\nc\n")
        XCTAssertEqual(kinds(result), [.conflict])
        XCTAssertEqual(merged("a\nb\nc\n", "a\nc\n", "a\nB\nc\n", conflict: .left), "a\nc\n")
    }

    func testBothDeleteTheSameLine() {
        XCTAssertEqual(kinds(chunks("a\nb\nc\n", "a\nc\n", "a\nc\n")), [.bothSame])
        XCTAssertEqual(merged("a\nb\nc\n", "a\nc\n", "a\nc\n"), "a\nc\n")
    }

    func testInsertionsAtTheSamePlace() {
        XCTAssertEqual(kinds(chunks("a\nc\n", "a\nL\nc\n", "a\nR\nc\n")), [.conflict])
        XCTAssertEqual(kinds(chunks("a\nc\n", "a\nX\nc\n", "a\nX\nc\n")), [.bothSame])
    }

    func testAnInsertionAndADeletionElsewhereAreBothKept() {
        let base = "1\n2\n3\n4\n5\n6\n"
        let left = "1\n2\nnew\n3\n4\n5\n6\n"
        let right = "1\n2\n3\n4\n6\n"
        XCTAssertEqual(merged(base, left, right), "1\n2\nnew\n3\n4\n6\n")
    }

    func testRangesCoverEachSideExactlyOnce() {
        let base = IDEDiffText("1\n2\n3\n4\n5\n6\n7\n")
        let left = IDEDiffText("1\nL\n3\nextra\n4\n5\n7\n")
        let right = IDEDiffText("1\n2\n3\n4\nR\n6\n7\n")
        let result = IDEMergeComputer.chunks(base: base, left: left, right: right)
        func covers(_ ranges: [Range<Int>], _ count: Int) -> Bool {
            var next = 0
            for range in ranges {
                guard range.lowerBound == next else { return false }
                next = range.upperBound
            }
            return next == count
        }
        XCTAssertTrue(covers(result.map(\.base), base.lineCount))
        XCTAssertTrue(covers(result.map(\.left), left.lineCount))
        XCTAssertTrue(covers(result.map(\.right), right.lineCount))
    }

    func testWindowsLineEndingsAreKept() {
        let base = "a\r\nb\r\nc\r\n"
        XCTAssertEqual(merged(base, "a\r\nL\r\nc\r\n", base), "a\r\nL\r\nc\r\n")
    }

    func testAMissingFinalNewlineSurvives() {
        XCTAssertEqual(merged("a\nb", "a\nL", "a\nb"), "a\nL")
    }

    /// Random edits of unique lines, merged by this and by `git merge-file`: when git finds no
    /// conflict the two outputs agree, and when git finds one so do we.
    func testAgreesWithGitMergeFileOnRandomEdits() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))
        var generator = SeededGenerator(seed: 0x5EED)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var counter = 0

        func edit(_ lines: [String]) -> [String] {
            var result = lines
            for _ in 0 ..< Int.random(in: 1 ... 3, using: &generator) {
                guard !result.isEmpty else { break }
                let index = Int.random(in: 0 ..< result.count, using: &generator)
                counter += 1
                switch Int.random(in: 0 ..< 3, using: &generator) {
                case 0: result[index] = "changed \(counter)"
                case 1: result.remove(at: index)
                default: result.insert("inserted \(counter)", at: index)
                }
            }
            return result
        }

        var agreed = 0
        var conflicts = 0
        for _ in 0 ..< 60 {
            let base = (0 ..< Int.random(in: 6 ... 18, using: &generator)).map { "line \($0)" }
            let left = edit(base)
            let right = edit(base)
            func text(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }
            for (name, lines) in [("base", base), ("left", left), ("right", right)] {
                try text(lines).write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["merge-file", "-p", "left", "base", "right"]
            process.currentDirectoryURL = directory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let b = IDEDiffText(text(base)), l = IDEDiffText(text(left)), r = IDEDiffText(text(right))
            let result = IDEMergeComputer.chunks(base: b, left: l, right: r)
            if process.terminationStatus == 0 {
                let ours = IDEMergeComputer.merged(base: b, left: l, right: r, chunks: result)
                XCTAssertEqual(IDEMergeComputer.conflictCount(result), 0, "git merged cleanly: \(left) | \(right)")
                XCTAssertEqual(ours, String(decoding: output, as: UTF8.self), "base \(base)\nleft \(left)\nright \(right)")
                agreed += 1
            } else {
                XCTAssertGreaterThan(IDEMergeComputer.conflictCount(result), 0, "git found a conflict: \(left) | \(right)")
                conflicts += 1
            }
        }
        XCTAssertGreaterThan(agreed, 5, "the oracle must see clean merges")
        XCTAssertGreaterThan(conflicts, 5, "the oracle must see conflicts")
    }
}

/// A repeatable random source, so a failing case can be rerun.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
