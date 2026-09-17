import Darwin
import Foundation
import XCTest
@testable import Penumbra

final class DocumentWriterTests: XCTestCase {
    override func tearDown() {
        DocumentWriter.debugFailAfterBytes = nil
        super.tearDown()
    }

    func testRoundTripContiguousLFCRLFEmojiAndEmpty() throws {
        for sample in ["hello\nworld\n", "ab\r\ncd", "café😀", ""] {
            let dest = try uniqueDest(named: "doc.txt")
            let footer = try DocumentWriter.write(.contiguous(sample), to: dest)
            let data = try Data(contentsOf: dest)
            XCTAssertEqual(data, Data(sample.utf8), sample.debugDescription)
            XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]), sample.debugDescription)
            assertFooterMatchesScan(footer, data: data, label: sample.debugDescription)
            assertNoWriterTemps(in: dest.deletingLastPathComponent())
        }
    }

    func testRoundTripPieceTreeLFCRLFEmojiAndEmpty() async throws {
        for sample in ["hello\nworld\n", "ab\r\ncd", "café😀", ""] {
            let source = try writeTempFile(sample)
            let loaded = try await TextViewState.load(contentsOf: source)
            XCTAssertEqual(loaded.stringView.materializeCount, 0)
            guard let snapshot = loaded.stringView.contentSnapshot() else {
                XCTFail("expected piece-tree snapshot for \(sample.debugDescription)")
                return
            }
            let dest = try uniqueDest(named: "doc.txt")
            let footer = try DocumentWriter.write(.pieceTree(snapshot), to: dest)
            let data = try Data(contentsOf: dest)
            XCTAssertEqual(data, Data(sample.utf8), sample.debugDescription)
            XCTAssertEqual(loaded.stringView.materializeCount, 0, sample.debugDescription)
            assertFooterMatchesScan(footer, data: data, label: sample.debugDescription)
        }
    }

    func testPieceTreeAfterMiddleInsertEqualsOriginalPlusEdits() async throws {
        let original = "abcdefghij\r\nxyz"
        let source = try writeTempFile(original)
        let loaded = try await TextViewState.load(contentsOf: source)
        loaded.stringView.replaceText(in: NSRange(location: 5, length: 0), with: "XYZ")
        XCTAssertEqual(loaded.stringView.materializeCount, 0)
        guard let snapshot = loaded.stringView.contentSnapshot() else {
            XCTFail("expected piece-tree snapshot")
            return
        }
        let dest = try uniqueDest(named: "edited.txt")
        let footer = try DocumentWriter.write(.pieceTree(snapshot), to: dest)
        let expected = "abcdeXYZfghij\r\nxyz"
        XCTAssertEqual(try Data(contentsOf: dest), Data(expected.utf8))
        XCTAssertEqual(loaded.stringView.materializeCount, 0)
        XCTAssertGreaterThan(loaded.stringView.pieceCount, 1)
        assertFooterMatchesScan(footer, data: try Data(contentsOf: dest), label: "middle insert")
    }

    func testCRLFSplitAcrossPiecesCountsAsOneLineFeed() async throws {
        let source = try writeTempFile("ab\r\ncd")
        let loaded = try await TextViewState.load(contentsOf: source)
        loaded.stringView.replaceText(in: NSRange(location: 3, length: 0), with: "X")
        loaded.stringView.replaceText(in: NSRange(location: 3, length: 1), with: "")
        XCTAssertGreaterThanOrEqual(loaded.stringView.pieceCount, 2)
        guard let snapshot = loaded.stringView.contentSnapshot() else {
            XCTFail("expected piece-tree snapshot")
            return
        }
        let dest = try uniqueDest(named: "crlf.txt")
        let footer = try DocumentWriter.write(.pieceTree(snapshot), to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), Data("ab\r\ncd".utf8))
        XCTAssertEqual(footer.lineFeedCount, 1)
        XCTAssertEqual(loaded.stringView.materializeCount, 0)
        assertFooterMatchesScan(footer, data: try Data(contentsOf: dest), label: "split CRLF")
    }

    func testCheckpointsMatchScannerOnLargeASCII() throws {
        let sample = String(repeating: "0123456789abcdef\n", count: 5_000)
        XCTAssertGreaterThan(sample.utf8.count, UTF8DocumentScanner.checkpointStride)
        let dest = try uniqueDest(named: "large.txt")
        let footer = try DocumentWriter.write(.contiguous(sample), to: dest)
        let data = try Data(contentsOf: dest)
        XCTAssertEqual(data, Data(sample.utf8))
        assertFooterMatchesScan(footer, data: data, label: "large ASCII")
        XCTAssertGreaterThan(footer.checkpoints.count, 1)
    }

    func testDebugFailAfterBytesLeavesDestIntact() throws {
        let dest = try uniqueDest(named: "keep.txt")
        let original = "original-bytes-must-survive"
        try original.write(to: dest, atomically: true, encoding: .utf8)
        DocumentWriter.debugFailAfterBytes = 8
        do {
            _ = try DocumentWriter.write(.contiguous(String(repeating: "x", count: 4_096)), to: dest)
            XCTFail("expected ioFailure")
        } catch DocumentWriteError.ioFailure {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), original)
        assertNoWriterTemps(in: dest.deletingLastPathComponent())
    }

    func testCancelledWriteLeavesDestUnchangedAndNoTemps() async throws {
        let dest = try uniqueDest(named: "cancel.txt")
        let original = "do-not-replace-me"
        try original.write(to: dest, atomically: true, encoding: .utf8)
        let payload = String(repeating: "cancel-me-\n", count: 20_000)
        let task = Task {
            try DocumentWriter.write(.contiguous(payload), to: dest, progress: { written, total in
                if written > 0, written == total {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }
        do {
            _ = try await task.value
            XCTFail("expected cancelled")
        } catch DocumentWriteError.cancelled {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), original)
        assertNoWriterTemps(in: dest.deletingLastPathComponent())
    }

    func testExistingXattrSurvivesOverwrite() throws {
        let dest = try uniqueDest(named: "xattr.txt")
        try "old".write(to: dest, atomically: true, encoding: .utf8)
        let name = "com.penumbra.test"
        let value = Data("keep-me".utf8)
        try dest.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw DocumentWriteError.ioFailure
            }
            XCTAssertEqual(value.withUnsafeBytes { raw in
                setxattr(path, name, raw.baseAddress, raw.count, 0, 0)
            }, 0)
        }
        _ = try DocumentWriter.write(.contiguous("new"), to: dest)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "new")
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = dest.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else {
                return -1
            }
            return getxattr(path, name, &buffer, buffer.count, 0, 0)
        }
        XCTAssertEqual(n, value.count)
        XCTAssertEqual(Data(buffer.prefix(n)), value)
        assertNoWriterTemps(in: dest.deletingLastPathComponent())
    }

    func testExistingExecutableModeIsPreserved() throws {
        let dest = try uniqueDest(named: "tool.sh")
        try "#!/bin/sh\necho old\n".write(to: dest, atomically: true, encoding: .utf8)
        try dest.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw DocumentWriteError.ioFailure
            }
            XCTAssertEqual(chmod(path, 0o755), 0)
        }
        _ = try DocumentWriter.write(.contiguous("#!/bin/sh\necho new\n"), to: dest)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "#!/bin/sh\necho new\n")
        var status = stat()
        XCTAssertEqual(dest.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return lstat(path, &status)
        }, 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o755)
    }

    func testNewFileIsNotLeftWorldUnreadable() throws {
        let dest = try uniqueDest(named: "new.txt")
        _ = try DocumentWriter.write(.contiguous("hello"), to: dest)
        var status = stat()
        XCTAssertEqual(dest.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return lstat(path, &status)
        }, 0)
        let mask = currentUmask()
        let expected = mode_t(0o666) & ~mask
        XCTAssertEqual(status.st_mode & 0o777, expected)
        if expected != 0o600 {
            XCTAssertNotEqual(status.st_mode & 0o777, 0o600)
        }
        assertNoWriterTemps(in: dest.deletingLastPathComponent())
    }

    func testUnsupportedEncodingThrows() throws {
        let dest = try uniqueDest(named: "utf16.txt")
        do {
            _ = try DocumentWriter.write(
                .contiguous("hello"),
                to: dest,
                options: DocumentWriteOptions(encoding: .utf16)
            )
            XCTFail("expected unsupportedEncoding")
        } catch DocumentWriteError.unsupportedEncoding {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        assertNoWriterTemps(in: dest.deletingLastPathComponent())
    }

    func testContentGenerationIncrementsOnReplaceAndStringSetter() {
        let view = StringView(string: "hello")
        XCTAssertEqual(view.contentGeneration, 0)
        view.replaceText(in: NSRange(location: 5, length: 0), with: "!")
        XCTAssertEqual(view.contentGeneration, 1)
        view.replaceText(in: NSRange(location: 0, length: 1), with: "H")
        XCTAssertEqual(view.contentGeneration, 2)
        view.string = "reset"
        XCTAssertEqual(view.contentGeneration, 3)
    }

    func testBOMIsNotWrittenFromLoadedFile() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(contentsOf: "hi".utf8)
        try bom.write(to: source)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: source)
        }
        let loaded = try await TextViewState.load(contentsOf: source)
        guard let snapshot = loaded.stringView.contentSnapshot() else {
            XCTFail("expected piece-tree snapshot")
            return
        }
        let dest = try uniqueDest(named: "nobom.txt")
        _ = try DocumentWriter.write(.pieceTree(snapshot), to: dest)
        let data = try Data(contentsOf: dest)
        XCTAssertEqual(data, Data("hi".utf8))
        XCTAssertEqual(loaded.stringView.materializeCount, 0)
    }

    private func uniqueDest(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent(name)
    }

    private func writeTempFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func assertFooterMatchesScan(
        _ footer: DocumentWriteFooter,
        data: Data,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scanned = data.withUnsafeBytes { UTF8DocumentScanner.scan($0) }
        XCTAssertEqual(footer.utf8Length, data.count, label, file: file, line: line)
        XCTAssertEqual(footer.utf16Length, scanned.utf16Length, label, file: file, line: line)
        XCTAssertEqual(footer.lineFeedCount, scanned.lineFeedCount, label, file: file, line: line)
        XCTAssertEqual(footer.checkpoints.count, scanned.checkpoints.count, label, file: file, line: line)
        for (index, pair) in zip(footer.checkpoints, scanned.checkpoints).enumerated() {
            XCTAssertEqual(pair.0.utf8Offset, pair.1.utf8Offset, "\(label) checkpoint \(index) utf8", file: file, line: line)
            XCTAssertEqual(pair.0.utf16Offset, pair.1.utf16Offset, "\(label) checkpoint \(index) utf16", file: file, line: line)
            XCTAssertEqual(pair.0.lineCount, pair.1.lineCount, "\(label) checkpoint \(index) lines", file: file, line: line)
        }
    }

    private func assertNoWriterTemps(in directory: URL, file: StaticString = #filePath, line: UInt = #line) {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let leftovers = items.filter {
            $0.lastPathComponent.contains(".penumbra-") && $0.pathExtension == "tmp"
        }
        XCTAssertTrue(leftovers.isEmpty, "leftover temps: \(leftovers)", file: file, line: line)
    }

    private func currentUmask() -> mode_t {
        let mask = umask(0)
        umask(mask)
        return mask
    }
}
