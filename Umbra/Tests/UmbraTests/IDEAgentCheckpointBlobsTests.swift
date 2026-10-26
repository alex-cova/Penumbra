import AgentKit
import Foundation
import XCTest

@testable import Umbra

final class IDEAgentCheckpointBlobsTests: XCTestCase {
    private var directory: URL!
    private var blobs: IDEAgentCheckpointBlobs!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("blobs-\(UUID().uuidString)", isDirectory: true)
        blobs = IDEAgentCheckpointBlobs(directory: directory)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testATextComesBackExactlyIncludingUnicodeAndLineEndings() {
        let run = UUID()
        let text = "héllo ✓ 日本語\r\nsecond line\n\n  trailing  "
        blobs.put(text, run: run, path: "src/A.java")
        XCTAssertEqual(blobs.get(run: run, path: "src/A.java"), text)
        blobs.put("", run: run, path: "empty.txt")
        XCTAssertEqual(blobs.get(run: run, path: "empty.txt"), "", "an empty original is not 'missing'")
    }

    func testRunsAndPathsDoNotShareAnything() {
        let first = UUID(), second = UUID()
        blobs.put("one", run: first, path: "A.txt")
        blobs.put("two", run: second, path: "A.txt")
        blobs.put("three", run: first, path: "B.txt")
        XCTAssertEqual(blobs.get(run: first, path: "A.txt"), "one")
        XCTAssertEqual(blobs.get(run: second, path: "A.txt"), "two")
        XCTAssertEqual(blobs.get(run: first, path: "B.txt"), "three")
        XCTAssertNil(blobs.get(run: second, path: "B.txt"))
        XCTAssertNil(blobs.get(run: UUID(), path: "A.txt"))
    }

    func testPathsThatLookAlikeStayApart() {
        let run = UUID()
        blobs.put("slash", run: run, path: "a/b")
        blobs.put("percent", run: run, path: "a%2Fb")
        blobs.put("dash", run: run, path: "a-b")
        XCTAssertEqual(blobs.get(run: run, path: "a/b"), "slash")
        XCTAssertEqual(blobs.get(run: run, path: "a%2Fb"), "percent")
        XCTAssertEqual(blobs.get(run: run, path: "a-b"), "dash")
    }

    func testAVeryLongPathStillWorksAndDiffersFromItsNeighbor() {
        let run = UUID()
        let long = String(repeating: "folder/", count: 60) + "A.java"
        let neighbor = String(repeating: "folder/", count: 60) + "B.java"
        blobs.put("long", run: run, path: long)
        blobs.put("neighbor", run: run, path: neighbor)
        XCTAssertLessThan(IDEAgentCheckpointBlobs.fileName(for: long).count, 200)
        XCTAssertEqual(blobs.get(run: run, path: long), "long")
        XCTAssertEqual(blobs.get(run: run, path: neighbor), "neighbor")
    }

    func testFilesAreReadableByTheUserAlone() throws {
        let run = UUID()
        blobs.put("secret source", run: run, path: "A.java")
        let folder = directory.appendingPathComponent(run.uuidString)
        let file = folder.appendingPathComponent(IDEAgentCheckpointBlobs.fileName(for: "A.java"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertNotEqual(try Data(contentsOf: file), Data("secret source".utf8), "stored compressed")
    }

    func testRemovingARunAndEverything() {
        let run = UUID(), other = UUID()
        blobs.put("a", run: run, path: "A")
        blobs.put("b", run: other, path: "B")
        XCTAssertTrue(blobs.hasRun(run))
        blobs.removeRun(run)
        XCTAssertFalse(blobs.hasRun(run))
        XCTAssertNil(blobs.get(run: run, path: "A"))
        XCTAssertEqual(blobs.get(run: other, path: "B"), "b")
        blobs.removeAll()
        XCTAssertNil(blobs.get(run: other, path: "B"))
    }

    func testPruningRemovesTheOldestRunsFirstAndSparesTheOnesToKeep() throws {
        let runs = (0..<4).map { _ in UUID() }
        for (index, run) in runs.enumerated() {
            // Incompressible text, so the size on disk is about the size written.
            blobs.put(String((0..<4_000).map { _ in Character(UnicodeScalar(UInt8.random(in: 33...126))) }), run: run, path: "f.txt")
            let folder = directory.appendingPathComponent(run.uuidString)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + index))], ofItemAtPath: folder.path)
        }
        XCTAssertTrue(blobs.prune(limit: 1_000_000).isEmpty, "under the limit nothing goes")

        let removed = blobs.prune(limit: 8_500, keeping: [runs[0]])
        XCTAssertFalse(removed.contains(runs[0]), "a run in use stays")
        XCTAssertEqual(removed.first, runs[1], "the oldest of the others goes first")
        XCTAssertTrue(blobs.hasRun(runs[0]) && blobs.hasRun(runs[3]))
        XCTAssertFalse(blobs.hasRun(runs[1]))
    }

    func testAMissingDirectoryIsFine() {
        XCTAssertNil(blobs.get(run: UUID(), path: "A"))
        XCTAssertTrue(blobs.prune(limit: 0).isEmpty)
        blobs.removeAll()
    }
}
