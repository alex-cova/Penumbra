import AppKit
import Foundation
import TestTreeSitterLanguages
import XCTest
@testable import Runestone

/// Coverage for reading a document's line metrics straight from UTF-8 instead of one UTF-16 unit at
/// a time.
///
/// `LineManager.rebuild()` used to walk `StringView.rangeOfNextNewLine(startingAt:)`, which on
/// piece-tree storage reads a single UTF-16 unit per call — an array allocation plus a byte walk
/// from the nearest 4 KiB checkpoint, for every unit in the document. It now asks the storage for
/// line metrics, and piece-tree storage answers by scanning its pieces' bytes with
/// `UTF8DocumentScanner.scanLines(_:state:onLine:)`.
///
/// The correctness risk that trade introduces is entirely about *buffer boundaries*: the single-pass
/// scanner can look ahead within its buffer, a per-piece scanner cannot. So most of this file is
/// equivalence testing across splits — against the single-pass scanner, and against the contiguous
/// `NSString.getLineStart` path that was already trusted.
final class DocumentLineScanTests: XCTestCase {
    /// Delimiters, multi-byte scalars, surrogate pairs, and both trailing-newline cases. Every
    /// fixture is exercised at every possible split, so these stay short on purpose.
    private static let fixtures: [String] = [
        "",
        "\n",
        "a",
        "abc",
        "a\nb",
        "a\nb\n",
        "aaa\nbbb\nccc",
        "a\r\nb",
        "a\r\nb\r\n",
        "a\rb",
        "a\r",
        "\r\n",
        "\r",
        "a\n\r\nb\rc",
        "café",
        "café\nnaïve\n",
        "😀",
        "a😀b\n😀",
        "emoji 😀 and 𝄞 clef\nsecond",
        "a\u{0085}b",
        "a\u{2028}b",
        "a\u{2029}b",
        "\u{0085}\u{2028}\u{2029}",
        "a\u{0085}\nb\u{2028}\r\nc",
        "line\twith\ttabs\nand more"
    ]

    // MARK: - Resumable scanner vs single pass

    func testResumableScanMatchesSinglePassAtEverySplit() {
        for text in Self.fixtures {
            let bytes = Array(text.utf8)
            let expected = bytes.withUnsafeBytes { UTF8DocumentScanner.lineMetrics(in: $0) }
            for split in 0...bytes.count {
                let actual = scanInChunks(bytes, cuts: [split])
                XCTAssertEqual(
                    actual,
                    expected,
                    "split at \(split) of \(text.debugDescription)"
                )
            }
        }
    }

    /// Three buffers, so a 3- or 4-byte scalar can be cut twice. A single split can only ever leave
    /// one continuation byte stranded; two splits can strand a sequence's middle byte alone in its
    /// own buffer, which is the case `completePartialScalar` has to keep waiting through.
    func testResumableScanMatchesSinglePassAtEveryPairOfSplits() {
        for text in Self.fixtures where text.utf8.count <= 24 {
            let bytes = Array(text.utf8)
            let expected = bytes.withUnsafeBytes { UTF8DocumentScanner.lineMetrics(in: $0) }
            for first in 0...bytes.count {
                for second in first...bytes.count {
                    let actual = scanInChunks(bytes, cuts: [first, second])
                    XCTAssertEqual(
                        actual,
                        expected,
                        "splits at \(first)/\(second) of \(text.debugDescription)"
                    )
                }
            }
        }
    }

    func testResumableScanSplitsEveryByteIntoItsOwnBuffer() {
        for text in Self.fixtures {
            let bytes = Array(text.utf8)
            let expected = bytes.withUnsafeBytes { UTF8DocumentScanner.lineMetrics(in: $0) }
            let actual = scanInChunks(bytes, cuts: Array(0...bytes.count))
            XCTAssertEqual(actual, expected, "byte-at-a-time scan of \(text.debugDescription)")
        }
    }

    /// An empty buffer must not finalize a carried CR. A piece tree can hold zero-length pieces, and
    /// treating one as the end of the document would split a CRLF into two delimiters.
    func testEmptyBufferBetweenCarriageReturnAndLineFeedKeepsCRLFTogether() {
        let bytes: [UInt8] = Array("a\r\nb".utf8)
        var state = UTF8DocumentScanner.LineScanState()
        var metrics: [LineMetric] = []
        bytes.withUnsafeBytes { raw in
            UTF8DocumentScanner.scanLines(UnsafeRawBufferPointer(rebasing: raw[0..<2]), state: &state) { metrics.append($0) }
            UTF8DocumentScanner.scanLines(UnsafeRawBufferPointer(start: nil, count: 0), state: &state) { metrics.append($0) }
            UTF8DocumentScanner.scanLines(UnsafeRawBufferPointer(rebasing: raw[2...]), state: &state) { metrics.append($0) }
        }
        UTF8DocumentScanner.finishLineScan(state: &state) { metrics.append($0) }
        XCTAssertEqual(metrics, [LineMetric(totalLength: 3, delimiterLength: 2), LineMetric(totalLength: 1, delimiterLength: 0)])
    }

    func testResumableScanReportsTruncatedSequenceAsInvalid() {
        // Lead byte of a 3-byte scalar with its continuation bytes missing.
        let bytes: [UInt8] = [0x61, 0xE2, 0x80]
        var state = UTF8DocumentScanner.LineScanState()
        var metrics: [LineMetric] = []
        bytes.withUnsafeBytes { raw in
            UTF8DocumentScanner.scanLines(raw, state: &state) { metrics.append($0) }
        }
        XCTAssertTrue(state.isValid, "the sequence is still incomplete, not yet known to be invalid")
        UTF8DocumentScanner.finishLineScan(state: &state) { metrics.append($0) }
        XCTAssertFalse(state.isValid)
        XCTAssertEqual(metrics, [LineMetric(totalLength: 2, delimiterLength: 0)])
    }

    func testResumableScanValidityMatchesSinglePassScan() {
        let invalidInputs: [[UInt8]] = [
            [0x61, 0xE2, 0x80],
            [0x80, 0x61],
            [0xFF],
            [0xC2],
            [0xE2, 0x28, 0xA1]
        ]
        for bytes in invalidInputs {
            let expected = bytes.withUnsafeBytes { UTF8DocumentScanner.isValidUTF8($0) }
            var state = UTF8DocumentScanner.LineScanState()
            bytes.withUnsafeBytes { raw in
                UTF8DocumentScanner.scanLines(raw, state: &state) { _ in }
            }
            UTF8DocumentScanner.finishLineScan(state: &state) { _ in }
            XCTAssertEqual(state.isValid, expected, "validity for \(bytes)")
        }
    }

    // MARK: - Piece tree vs contiguous storage

    func testPieceTreeLineIndexMatchesContiguousLineIndex() {
        for text in Self.fixtures {
            assertLineIndexesAgree(for: text)
        }
    }

    func testPieceTreeLineIndexMatchesContiguousForRealisticDocuments() {
        assertLineIndexesAgree(for: String(repeating: "let x = 1\n", count: 500))
        assertLineIndexesAgree(for: String(repeating: "let x = 1\r\n", count: 500))
        assertLineIndexesAgree(for: (0..<200).map { "line \($0) 😀 café" }.joined(separator: "\n"))
        assertLineIndexesAgree(for: (0..<200).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
    }

    /// With a small stride every few bytes start a new piece, so the per-piece scan is forced across
    /// boundaries that a 64 KiB default would need megabyte-scale fixtures to reach.
    func testPieceTreeLineIndexMatchesContiguousWithTinyPieces() {
        for stride in [1, 2, 3, 4, 7, 16] {
            withCheckpointStride(stride) {
                for text in Self.fixtures {
                    assertLineIndexesAgree(for: text, context: "stride \(stride)")
                }
                assertLineIndexesAgree(for: "a\r\nb\r\nc\r\n", context: "stride \(stride)")
                assertLineIndexesAgree(for: "😀\r\n😀\u{2028}😀", context: "stride \(stride)")
            }
        }
    }

    func testSeededPieceTreeNeverSplitsACRLF() {
        withCheckpointStride(2) {
            let tree = PieceTree(string: "ab\r\ncd\r\nef")
            XCTAssertGreaterThan(tree.pieceCount, 1, "stride must actually force several pieces")
            // One delimiter per CRLF. A piece boundary between the CR and the LF would make each
            // half count its own line feed and report three lines as five.
            XCTAssertEqual(
                tree.lineMetrics(),
                [
                    LineMetric(totalLength: 4, delimiterLength: 2),
                    LineMetric(totalLength: 4, delimiterLength: 2),
                    LineMetric(totalLength: 2, delimiterLength: 0)
                ]
            )
        }
    }

    func testSeededPieceTreeRoundTripsContentAndLength() {
        withCheckpointStride(3) {
            for text in Self.fixtures {
                let tree = PieceTree(string: text)
                XCTAssertEqual(tree.utf16Length, (text as NSString).length, text.debugDescription)
                XCTAssertEqual(tree.substring(in: NSRange(location: 0, length: tree.utf16Length)), text, text.debugDescription)
            }
        }
    }

    // MARK: - Line index after edits

    func testLineIndexMatchesContiguousAfterEdits() {
        let edits: [(NSRange, String)] = [
            (NSRange(location: 0, length: 0), "X"),
            (NSRange(location: 3, length: 0), "\n"),
            (NSRange(location: 2, length: 1), ""),
            (NSRange(location: 5, length: 0), "\r\n"),
            (NSRange(location: 1, length: 0), "😀"),
            (NSRange(location: 4, length: 2), "ab")
        ]
        withCheckpointStride(4) {
            let piece = StringView(pieceTree: PieceTree(string: "aaa\nbbb\nccc\nddd"))
            let contiguous = StringView(string: NSMutableString(string: "aaa\nbbb\nccc\nddd"))
            for (index, edit) in edits.enumerated() {
                let capped = clamp(edit.0, to: piece.length)
                piece.replaceText(in: capped, with: edit.1)
                contiguous.replaceText(in: capped, with: edit.1)
                XCTAssertEqual(piece.string as String, contiguous.string as String, "content after edit \(index)")
                assertLineIndexesAgree(pieceView: piece, contiguousView: contiguous, context: "after edit \(index)")
            }
        }
    }

    /// `split(atUTF16:)` can put a boundary anywhere, including between a CR and its LF — unlike the
    /// seed and insert paths, which deliberately avoid it. The carried `pendingCR` is what keeps the
    /// pair counted as one delimiter.
    func testLineIndexIsCorrectWhenAnEditSplitsAPieceBetweenCRAndLF() {
        let view = StringView(pieceTree: PieceTree(string: "ab\r\ncd"))
        view.replaceText(in: NSRange(location: 3, length: 0), with: "X")
        view.replaceText(in: NSRange(location: 3, length: 1), with: "")
        XCTAssertEqual(view.string as String, "ab\r\ncd")
        XCTAssertGreaterThanOrEqual(view.pieceCount, 2, "the edit must leave a boundary inside the CRLF")
        XCTAssertEqual(
            view.lineMetrics(),
            [LineMetric(totalLength: 4, delimiterLength: 2), LineMetric(totalLength: 2, delimiterLength: 0)]
        )
    }

    func testLineIndexIsCorrectAfterDeletingAcrossPieces() {
        withCheckpointStride(4) {
            let piece = StringView(pieceTree: PieceTree(string: "one\ntwo\nthree\nfour\nfive"))
            let contiguous = StringView(string: NSMutableString(string: "one\ntwo\nthree\nfour\nfive"))
            let range = NSRange(location: 2, length: 12)
            piece.replaceText(in: range, with: "")
            contiguous.replaceText(in: range, with: "")
            XCTAssertEqual(piece.string as String, contiguous.string as String)
            assertLineIndexesAgree(pieceView: piece, contiguousView: contiguous)
        }
    }

    // MARK: - Routing

    /// Only piece-tree storage answers `lineMetrics()`. If contiguous storage started answering it
    /// too, `rebuild()` would stop using `NSString.getLineStart` — the faster option there — and the
    /// differential tests above would keep passing either way, so assert the decision directly.
    func testOnlyPieceTreeStorageReportsLineMetrics() {
        XCTAssertNil(StringView(string: NSMutableString(string: "a\nb")).lineMetrics())
        XCTAssertEqual(
            StringView(pieceTree: PieceTree(string: "a\nb")).lineMetrics(),
            [LineMetric(totalLength: 2, delimiterLength: 1), LineMetric(totalLength: 1, delimiterLength: 0)]
        )
    }

    // MARK: - Entry points

    /// All three callers of `LineManager.rebuild()` share the storage-aware path. A large document is
    /// piece-tree-backed whichever entry point built it, so all three must agree with the small,
    /// contiguous version of the same text.
    func testLargeDocumentEntryPointsAgreeOnLineCount() {
        let text = String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 8_000)
        let expectedLineCount = 8_001

        let state = TextViewState(text: text)
        XCTAssertTrue(state.stringView.usesPieceTree, "fixture must be over the 256 KiB piece-tree threshold")
        XCTAssertEqual(state.lineManager.lineCount, expectedLineCount, "TextViewState(text:)")

        let assigned = StringView(string: NSMutableString(string: text))
        let assignedLineManager = LineManager(stringView: assigned)
        assignedLineManager.rebuild()
        XCTAssertTrue(assigned.usesPieceTree)
        XCTAssertEqual(assignedLineManager.lineCount, expectedLineCount, "NSString assignment")

        let contiguous = StringView(string: NSMutableString(string: "the quick brown fox jumps over the lazy dog\n"))
        let contiguousLineManager = LineManager(stringView: contiguous)
        contiguousLineManager.rebuild()
        XCTAssertFalse(contiguous.usesPieceTree)
        XCTAssertEqual(contiguousLineManager.lineCount, 2)
    }

    @MainActor
    func testAssigningLargeTextToTextViewBuildsTheSameLineIndex() {
        let text = String(repeating: "abcdefghij\n", count: 30_000)
        let textInputView = TextInputView(theme: DefaultTheme())
        textInputView.string = text as NSString
        XCTAssertTrue(textInputView.stringView.usesPieceTree, "fixture must force piece-tree storage")
        XCTAssertEqual(textInputView.lineManager.lineCount, 30_001)
        XCTAssertEqual(textInputView.lineManager.line(atRow: 0).data.totalLength, 11)
        XCTAssertEqual(textInputView.lineManager.line(atRow: 29_999).data.totalLength, 11)
        XCTAssertEqual(textInputView.lineManager.line(atRow: 30_000).data.totalLength, 0)
    }

    func testStringSyntaxHighlighterHandlesADocumentOverThePieceTreeThreshold() {
        let highlighter = StringSyntaxHighlighter(language: .json)
        let text = "[\n" + String(repeating: "  \"abcdefghijklmnopqrstuvwxyz\",\n", count: 9_000) + "  \"z\"\n]"
        XCTAssertGreaterThanOrEqual((text as NSString).length, StringView.pieceTreeUntitledThreshold)
        let highlighted = highlighter.syntaxHighlight(text)
        XCTAssertEqual(highlighted.string, text)
    }

    // MARK: - Helpers

    private func scanInChunks(_ bytes: [UInt8], cuts: [Int]) -> [LineMetric] {
        var metrics: [LineMetric] = []
        var state = UTF8DocumentScanner.LineScanState()
        let bounds = ([0] + cuts + [bytes.count]).sorted()
        bytes.withUnsafeBytes { raw in
            for index in 1..<bounds.count {
                let lower = bounds[index - 1]
                let upper = bounds[index]
                guard upper > lower else {
                    continue
                }
                UTF8DocumentScanner.scanLines(UnsafeRawBufferPointer(rebasing: raw[lower..<upper]), state: &state) {
                    metrics.append($0)
                }
            }
        }
        UTF8DocumentScanner.finishLineScan(state: &state) { metrics.append($0) }
        return metrics
    }

    private func withCheckpointStride(_ stride: Int, _ body: () -> Void) {
        let original = UTF8DocumentScanner.checkpointStride
        UTF8DocumentScanner.checkpointStride = stride
        defer { UTF8DocumentScanner.checkpointStride = original }
        body()
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    private func assertLineIndexesAgree(
        for text: String,
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pieceView = StringView(pieceTree: PieceTree(string: text))
        let contiguousView = StringView(string: NSMutableString(string: text))
        XCTAssertFalse(contiguousView.usesPieceTree, "fixture should be small enough to stay contiguous", file: file, line: line)
        assertLineIndexesAgree(
            pieceView: pieceView,
            contiguousView: contiguousView,
            context: "\(text.debugDescription) \(context)",
            file: file,
            line: line
        )
    }

    private func assertLineIndexesAgree(
        pieceView: StringView,
        contiguousView: StringView,
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let piece = LineManager(stringView: pieceView)
        piece.rebuild()
        let contiguous = LineManager(stringView: contiguousView)
        contiguous.rebuild()
        XCTAssertEqual(piece.lineCount, contiguous.lineCount, "line count for \(context)", file: file, line: line)
        guard piece.lineCount == contiguous.lineCount else {
            return
        }
        for row in 0..<contiguous.lineCount {
            let expected = contiguous.line(atRow: row)
            let actual = piece.line(atRow: row)
            XCTAssertEqual(actual.location, expected.location, "row \(row) location for \(context)", file: file, line: line)
            XCTAssertEqual(
                actual.data.totalLength,
                expected.data.totalLength,
                "row \(row) totalLength for \(context)",
                file: file,
                line: line
            )
            XCTAssertEqual(
                actual.data.delimiterLength,
                expected.data.delimiterLength,
                "row \(row) delimiterLength for \(context)",
                file: file,
                line: line
            )
        }
    }
}
