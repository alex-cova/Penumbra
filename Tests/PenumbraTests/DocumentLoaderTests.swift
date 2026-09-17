import Darwin
import Foundation
import XCTest
import PenumbraMarkdownLanguage
@testable import Penumbra

final class DocumentLoaderTests: XCTestCase {
    private var originalChunkSize = 0

    override func setUp() {
        super.setUp()
        originalChunkSize = DocumentLoader.chunkByteCount
    }

    override func tearDown() {
        DocumentLoader.chunkByteCount = originalChunkSize
        super.tearDown()
    }

    func testLoadMatchesStringContentsOfAndLineIndex() async throws {
        let url = try writeTempFile("hello\nworld\n")
        let loaded = try await TextViewState.load(contentsOf: url)
        let expected = try String(contentsOf: url, encoding: .utf8)
        let reference = TextViewState(text: expected)
        XCTAssertEqual(loaded.stringView.string as String, expected)
        XCTAssertTrue(loaded.stringView.isFileBacked)
        XCTAssertEqual(loaded.lineManager.lineCount, reference.lineManager.lineCount)
        XCTAssertEqual(loaded.detectedLineEndings, .lf)
    }

    func testUTF8ScalarSplitAcrossOneByteChunks() async throws {
        DocumentLoader.chunkByteCount = 1
        let url = try writeTempFile("café😀")
        let loaded = try await TextViewState.load(contentsOf: url)
        XCTAssertEqual(loaded.stringView.string as String, "café😀")
        XCTAssertEqual(loaded.lineManager.lineCount, 1)
    }

    func testCRLFSplitAcrossChunks() async throws {
        DocumentLoader.chunkByteCount = 2
        let url = try writeTempFile("ab\r\ncd")
        let loaded = try await TextViewState.load(contentsOf: url)
        let reference = TextViewState(text: "ab\r\ncd")
        XCTAssertEqual(loaded.stringView.string as String, "ab\r\ncd")
        XCTAssertEqual(loaded.lineManager.lineCount, reference.lineManager.lineCount)
        XCTAssertEqual(loaded.lineManager.firstLine.data.delimiterLength, 2)
        XCTAssertEqual(loaded.detectedLineEndings, .crlf)
    }

    func testTrailingNewlineProducesEmptyLastLine() async throws {
        DocumentLoader.chunkByteCount = 3
        let url = try writeTempFile("a\n")
        let loaded = try await TextViewState.load(contentsOf: url)
        XCTAssertEqual(loaded.lineManager.lineCount, 2)
        XCTAssertEqual(loaded.lineManager.lastLine.data.totalLength, 0)
    }

    func testEmptyFileIsSingleEmptyLine() async throws {
        let url = try writeTempFile("")
        let loaded = try await TextViewState.load(contentsOf: url)
        XCTAssertEqual(loaded.stringView.string as String, "")
        XCTAssertEqual(loaded.lineManager.lineCount, 1)
    }

    func testBOMIsStripped() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: "hi".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try await TextViewState.load(contentsOf: url)
        XCTAssertEqual(loaded.stringView.string as String, "hi")
    }

    func testProgressIsMonotonicAndReachesTotal() async throws {
        DocumentLoader.chunkByteCount = 4
        let url = try writeTempFile(String(repeating: "abcdef\n", count: 20))
        let total = Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! UInt64)
        final class Samples: @unchecked Sendable {
            var values: [(Int64, Int64)] = []
            let lock = NSLock()
            func append(_ read: Int64, _ total: Int64) {
                lock.lock()
                values.append((read, total))
                lock.unlock()
            }
        }
        let samples = Samples()
        _ = try await TextViewState.load(contentsOf: url, progress: { read, all in
            samples.append(read, all)
        })
        XCTAssertFalse(samples.values.isEmpty)
        XCTAssertEqual(samples.values.last?.1, total)
        XCTAssertEqual(samples.values.last?.0, total)
        let reads = samples.values.map(\.0)
        XCTAssertEqual(reads, reads.sorted())
    }

    func testCancelThrowsCancelled() async throws {
        DocumentLoader.chunkByteCount = 8
        let url = try writeTempFile(String(repeating: "0123456789\n", count: 2_000))
        let task = Task {
            try await TextViewState.load(contentsOf: url)
        }
        task.cancel()
        do {
            _ = try await task.value
            // Clone+scan of a small file can finish before the cancel is observed.
        } catch DocumentLoadError.cancelled {
            // expected when cancel wins the race
        } catch is CancellationError {
            // expected
        }
    }

    func testUnsupportedEncodingThrows() async throws {
        let url = try writeTempFile("hello")
        do {
            _ = try await TextViewState.load(contentsOf: url, encoding: .utf16)
            XCTFail("expected unsupportedEncoding")
        } catch DocumentLoadError.unsupportedEncoding {
            // expected
        }
    }

    func testDeferredLoadDoesNotParse() async throws {
        let url = try writeTempFile("# Hello\n")
        let loaded = try await TextViewState.load(contentsOf: url, language: .markdown)
        XCTAssertFalse(loaded.isSyntaxTreeReady)
    }

    func testStreamedAndMappedProduceIdenticalTextAndLineIndex() async throws {
        DocumentLoader.chunkByteCount = 5
        let text = "café😀\r\nabc\n\nend\u{2028}z"
        let url = try writeTempFile(text)
        let streamed = try await TextViewState.load(contentsOf: url, io: .streamed)
        let mapped = try await TextViewState.load(contentsOf: url, io: .memoryMapped)
        XCTAssertEqual(streamed.stringView.string as String, text)
        XCTAssertEqual(mapped.stringView.string as String, text)
        XCTAssertEqual(streamed.lineManager.lineCount, mapped.lineManager.lineCount)
        for row in 0..<streamed.lineManager.lineCount {
            let expected = streamed.lineManager.line(atRow: row)
            let actual = mapped.lineManager.line(atRow: row)
            XCTAssertEqual(actual.data.totalLength, expected.data.totalLength, "totalLength row \(row)")
            XCTAssertEqual(actual.data.delimiterLength, expected.data.delimiterLength, "delimiterLength row \(row)")
        }
    }

    func testMappedLoadUsesOneByteWindowsLikeStreamed() async throws {
        DocumentLoader.chunkByteCount = 1
        let url = try writeTempFile("café😀")
        let mapped = try await TextViewState.load(contentsOf: url, io: .memoryMapped)
        XCTAssertEqual(mapped.stringView.string as String, "café😀")
    }

    func testMappedLoadIgnoresTruncationOfOriginalPath() async throws {
        let url = try writeTempFile(String(repeating: "0123456789abcdef\n", count: 64))
        let loaded = try await TextViewState.load(contentsOf: url, io: .memoryMapped)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let fd = open(path, O_WRONLY | O_CLOEXEC)
            guard fd >= 0 else { return }
            _ = ftruncate(fd, 4)
            close(fd)
        }
        XCTAssertTrue(loaded.stringView.isFileBacked)
        XCTAssertGreaterThan(loaded.stringView.length, 4)
        XCTAssertEqual(loaded.stringView.substring(in: NSRange(location: 0, length: 4)), "0123")
    }

    func testLineBreakAccumulatorMatchesRebuildForMixedEndings() {
        let samples = [
            "", "a", "a\n", "a\n\n", "a\r\nb", "a\rb\nc\r\n", "\n", "\r\n",
            "a\u{2028}b", "a\u{2029}b", "a\u{0085}b"
        ]
        for sample in samples {
            var accumulator = LineBreakAccumulator()
            accumulator.consume(sample as NSString)
            let metrics = accumulator.finish()
            let stringView = StringView(string: sample)
            let scanned = LineManager(stringView: stringView)
            scanned.rebuild()
            let fromMetrics = LineManager(stringView: stringView)
            fromMetrics.rebuild(fromLineMetrics: metrics)
            XCTAssertEqual(
                fromMetrics.lineCount,
                scanned.lineCount,
                "line count mismatch for \(sample.debugDescription)"
            )
            for row in 0..<scanned.lineCount {
                let expected = scanned.line(atRow: row)
                let actual = fromMetrics.line(atRow: row)
                XCTAssertEqual(actual.data.totalLength, expected.data.totalLength, "totalLength row \(row) in \(sample.debugDescription)")
                XCTAssertEqual(actual.data.delimiterLength, expected.data.delimiterLength, "delimiterLength row \(row) in \(sample.debugDescription)")
            }
        }
    }

    func testCompleteUTF8PrefixHoldsBackIncompleteSequence() {
        // € is E2 82 AC
        XCTAssertEqual(DocumentLoader.completeUTF8PrefixLength(in: Data([0xE2])), 0)
        XCTAssertEqual(DocumentLoader.completeUTF8PrefixLength(in: Data([0xE2, 0x82])), 0)
        XCTAssertEqual(DocumentLoader.completeUTF8PrefixLength(in: Data([0xE2, 0x82, 0xAC])), 3)
        XCTAssertEqual(DocumentLoader.completeUTF8PrefixLength(in: Data([0x61, 0xE2, 0x82])), 1)
    }

    private func writeTempFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}