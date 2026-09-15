import XCTest
@testable import Runestone

final class PieceTreeTests: XCTestCase {
    func testContiguousAndPieceTreeAgreeOnEdits() throws {
        let samples = ["hello", "a\nb\nc", "café😀", "ab\r\ncd", ""]
        for original in samples {
            let url = try writeTemp(original)
            let loaded = try awaitLoad(url)
            let contiguous = StringView(string: original)
            XCTAssertEqual(loaded.string as String, original)
            let edits: [(NSRange, String)] = [
                (NSRange(location: 0, length: 0), "X"),
                (NSRange(location: 1, length: 1), ""),
                (NSRange(location: min(1, loaded.length), length: 0), "yz")
            ]
            for (range, text) in edits {
                let capped = NSRange(
                    location: min(range.location, loaded.length),
                    length: min(range.length, max(0, loaded.length - min(range.location, loaded.length)))
                )
                loaded.replaceText(in: capped, with: text)
                contiguous.replaceText(in: capped, with: text)
                XCTAssertEqual(loaded.string as String, contiguous.string as String, "after \(text) in \(original)")
            }
        }
    }

    func testMiddleInsertDoesNotRequireFullMaterializeForSubstring() throws {
        let url = try writeTemp("abcdefghij")
        let view = try awaitLoad(url)
        XCTAssertTrue(view.isFileBacked)
        view.replaceText(in: NSRange(location: 5, length: 0), with: "XYZ")
        XCTAssertEqual(view.substring(in: NSRange(location: 3, length: 7)), "deXYZfg")
        XCTAssertEqual(view.length, 13)
    }

    func testSequentialTypingExtendsAddBuffer() throws {
        let url = try writeTemp("hello world")
        let view = try awaitLoad(url)
        view.replaceText(in: NSRange(location: 5, length: 0), with: "!")
        view.replaceText(in: NSRange(location: 6, length: 0), with: "!")
        view.replaceText(in: NSRange(location: 7, length: 0), with: "!")
        XCTAssertEqual(view.string as String, "hello!!! world")
        XCTAssertLessThanOrEqual(view.pieceCount, 3)
    }

    func testCRLFSplitAcrossPiecesStillOneDelimiter() throws {
        let url = try writeTemp("ab\r\ncd")
        let view = try awaitLoad(url)
        view.replaceText(in: NSRange(location: 3, length: 0), with: "X")
        view.replaceText(in: NSRange(location: 3, length: 1), with: "")
        XCTAssertEqual(view.string as String, "ab\r\ncd")
        XCTAssertGreaterThanOrEqual(view.pieceCount, 2)
        XCTAssertEqual(view.rangeOfNextNewLine(startingAt: 0), NSRange(location: 2, length: 2))
        let lineManager = LineManager(stringView: view)
        lineManager.rebuild()
        XCTAssertEqual(lineManager.firstLine.data.delimiterLength, 2)
        XCTAssertEqual(lineManager.lineCount, 2)
    }

    func testSurrogatePairSubstringRanges() throws {
        let text = "a😀bc"
        let tree = PieceTree(string: text)
        let groundTruth = text as NSString
        for location in 0..<groundTruth.length {
            for length in 1...(groundTruth.length - location) {
                let range = NSRange(location: location, length: length)
                let expected = groundTruth.substring(with: range)
                let actual = tree.substring(in: range)
                XCTAssertEqual(actual, expected, "range \(range)")
            }
        }
    }

    func testFileBackedSurrogatePairSubstringRanges() throws {
        let text = "prefix😀suffix"
        let url = try writeTemp(text)
        let view = try awaitLoad(url)
        let groundTruth = text as NSString
        for location in 0..<groundTruth.length {
            for length in 1...(groundTruth.length - location) {
                let range = NSRange(location: location, length: length)
                XCTAssertEqual(view.substring(in: range), groundTruth.substring(with: range), "range \(range)")
            }
        }
    }

    func testAddBufferBytesAcrossSurrogatePairBoundary() throws {
        var text = String(repeating: "x", count: 300_000)
        for offset in stride(from: 4_000, to: text.count, by: 4_096) {
            let index = text.index(text.startIndex, offsetBy: min(offset, text.count - 1))
            text.replaceSubrange(index..<text.index(after: index), with: "😀")
        }
        let pieceTreeView = StringView(string: text)
        XCTAssertTrue(pieceTreeView.usesPieceTree)
        let groundTruth = text as NSString
        var byteIndex = ByteCount(0)
        let chunkSize = ByteCount(4 * 1_024)
        while byteIndex < pieceTreeView.byteCount {
            let end = min(byteIndex + chunkSize, pieceTreeView.byteCount)
            try assertBytes(pieceTreeView, matches: groundTruth, in: ByteRange(from: byteIndex, to: end), chunk: 0)
            byteIndex = end
        }
    }

    func testUTF8ScalarSplitAcrossPieces() throws {
        let original = "café😀xyz"
        let url = try writeTemp(original)
        let view = try awaitLoad(url)
        let contiguous = StringView(string: original)
        view.replaceText(in: NSRange(location: 3, length: 0), with: "|")
        contiguous.replaceText(in: NSRange(location: 3, length: 0), with: "|")
        view.replaceText(in: NSRange(location: 5, length: 0), with: "|")
        contiguous.replaceText(in: NSRange(location: 5, length: 0), with: "|")
        view.replaceText(in: NSRange(location: 8, length: 0), with: "|")
        contiguous.replaceText(in: NSRange(location: 8, length: 0), with: "|")
        XCTAssertEqual(view.string as String, contiguous.string as String)
        XCTAssertEqual(view.substring(in: NSRange(location: 0, length: view.length)), contiguous.string as String)
    }

    func testPropertyStyleRandomEditsMatchContiguous() throws {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let alphabet = Array("abcé\r\n\t ")
        for round in 0..<8 {
            var text = randomString(length: 24 + round, alphabet: alphabet, rng: &rng)
            let url = try writeTemp(text)
            let view = try awaitLoad(url)
            let contiguous = StringView(string: text)
            for _ in 0..<100 {
                let location = rng.next(upperBound: UInt64(max(view.length, 1)))
                let maxLen = max(0, view.length - Int(location))
                let length = maxLen == 0 ? 0 : Int(rng.next(upperBound: UInt64(min(maxLen, 4) + 1)))
                let insertion = randomString(length: Int(rng.next(upperBound: 4)), alphabet: alphabet, rng: &rng)
                let range = NSRange(location: Int(location), length: length)
                view.replaceText(in: range, with: insertion)
                contiguous.replaceText(in: range, with: insertion)
                XCTAssertEqual(view.length, contiguous.length)
                if view.length <= 80 {
                    XCTAssertEqual(view.string as String, contiguous.string as String)
                } else {
                    let sampleLoc = Int(rng.next(upperBound: UInt64(max(view.length, 1))))
                    let sampleLen = min(16, view.length - sampleLoc)
                    let sample = NSRange(location: sampleLoc, length: sampleLen)
                    XCTAssertEqual(view.substring(in: sample), contiguous.substring(in: sample))
                }
            }
            XCTAssertEqual(view.string as String, contiguous.string as String)
        }
    }

    func testPrefetchDoesNotWillNeedWholeOriginalPiece() throws {
        let text = String(repeating: "abcdefghij\n", count: 40_000)
        let url = try writeTemp(text)
        let view = try awaitLoad(url)
        XCTAssertGreaterThan(view.length, PieceTree.prefetchByteCap)
        view.prefetch(utf16Range: NSRange(location: 0, length: view.length))
        XCTAssertGreaterThan(view.lastPrefetchByteCount, 0)
        XCTAssertLessThanOrEqual(view.lastPrefetchByteCount, PieceTree.prefetchByteCap)
    }

    func testComposedCharacterSequenceCoversFamilyEmoji() throws {
        let emoji = "👨‍👩‍👧‍👦"
        let url = try writeTemp(emoji)
        let view = try awaitLoad(url)
        let expected = (emoji as NSString).length
        XCTAssertEqual(view.rangeOfComposedCharacterSequence(at: 0).length, expected)
        XCTAssertEqual(view.rangeOfComposedCharacterSequence(at: 5).length, expected)
        XCTAssertEqual(view.rangeOfComposedCharacterSequence(at: expected - 1).length, expected)
    }

    func testUntitledPieceTreeIsNotFileBacked() {
        let text = String(repeating: "ab\n", count: 100)
        let tree = PieceTree(string: text)
        XCTAssertFalse(tree.isFileMapped)
        XCTAssertEqual(tree.utf16Length, (text as NSString).length)
        tree.replaceText(in: NSRange(location: 0, length: 0), with: "X")
        XCTAssertEqual(tree.substring(in: NSRange(location: 0, length: 3)), "Xab")
        let newline = tree.rangeOfNextNewLine(startingAt: 0)
        XCTAssertEqual(newline, NSRange(location: 3, length: 1))
        XCTAssertEqual(tree.paragraphStart(before: 4), 4)
        let found = tree.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: 0, length: tree.utf16Length))
        XCTAssertEqual(found, NSRange(location: 3, length: 1))
    }

    func testTextViewStateUsesUntitledPieceTreeAboveThreshold() {
        let text = String(repeating: "a", count: StringView.pieceTreeUntitledThreshold)
        let state = TextViewState(text: text)
        XCTAssertTrue(state.stringView.usesPieceTree)
        XCTAssertFalse(state.stringView.isFileBacked)
    }

    func testCompactCollapsesToSingleOriginalPiece() throws {
        let url = try writeTemp("abcdefghij")
        let view = try awaitLoad(url)
        view.replaceText(in: NSRange(location: 5, length: 0), with: "XYZ")
        let before = view.substring(in: NSRange(location: 0, length: view.length))
        XCTAssertEqual(before, "abcdeXYZfghij")
        XCTAssertGreaterThan(view.pieceCount, 1)
        XCTAssertGreaterThan(view.addBufferByteCount, 0)
        let generation = view.contentGeneration
        guard let snapshot = view.contentSnapshot() else {
            return XCTFail("expected piece-tree snapshot")
        }
        let dest = try writeTemp("")
        let footer = try DocumentWriter.write(.pieceTree(snapshot), to: dest)
        guard let mapping = FileMapping.openPrivateClone(of: dest) else {
            return XCTFail("expected private clone")
        }
        view.compactPieceTree(mapping: mapping, footer: footer)
        XCTAssertEqual(view.pieceCount, 1)
        XCTAssertEqual(view.substring(in: NSRange(location: 0, length: view.length)), before)
        XCTAssertEqual(view.addBufferByteCount, 0)
        XCTAssertEqual(view.contentGeneration, generation)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), before)
    }

    func testCompactPreservesSplitCRLFAsOneDelimiter() throws {
        let url = try writeTemp("ab\r\ncd")
        let view = try awaitLoad(url)
        view.replaceText(in: NSRange(location: 3, length: 0), with: "X")
        view.replaceText(in: NSRange(location: 3, length: 1), with: "")
        XCTAssertEqual(view.string as String, "ab\r\ncd")
        XCTAssertGreaterThanOrEqual(view.pieceCount, 2)
        XCTAssertEqual(view.rangeOfNextNewLine(startingAt: 0), NSRange(location: 2, length: 2))
        let before = view.substring(in: NSRange(location: 0, length: view.length))
        guard let snapshot = view.contentSnapshot() else {
            return XCTFail("expected piece-tree snapshot")
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let footer = try DocumentWriter.write(.pieceTree(snapshot), to: dest)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dest)
        }
        guard let mapping = FileMapping.openPrivateClone(of: dest) else {
            return XCTFail("expected private clone")
        }
        view.compactPieceTree(mapping: mapping, footer: footer)
        XCTAssertEqual(view.pieceCount, 1)
        XCTAssertEqual(view.substring(in: NSRange(location: 0, length: view.length)), before)
        XCTAssertEqual(view.addBufferByteCount, 0)
        XCTAssertEqual(view.rangeOfNextNewLine(startingAt: 0), NSRange(location: 2, length: 2))
        XCTAssertEqual(try Data(contentsOf: dest), Data("ab\r\ncd".utf8))
    }

    func testScatteredInsertsStayEquivalent() throws {
        let url = try writeTemp(String(repeating: "0123456789", count: 20))
        let view = try awaitLoad(url)
        let contiguous = StringView(string: view.string as String)
        for offset in stride(from: 0, to: 200, by: 10).reversed() {
            view.replaceText(in: NSRange(location: offset, length: 0), with: "X")
            contiguous.replaceText(in: NSRange(location: offset, length: 0), with: "X")
        }
        XCTAssertGreaterThan(view.pieceCount, 3)
        XCTAssertEqual(view.string as String, contiguous.string as String)
    }

    // MARK: - `.add`-buffer `bytes(in:)` offset cursor (TreeSitterParser's reader callback path)

    /// `TreeSitterLanguageLayer.parseUsingReader()` reads a document in ~4KB chunks via
    /// `StringView.bytes(in:)`, strictly forward, while parsing. For an untitled document above
    /// `StringView.pieceTreeUntitledThreshold` this lands on a single large `.add`-buffer piece,
    /// which has no checkpoint table (unlike `.original`/file-mapped pieces) — resolving each
    /// chunk's UTF-16→UTF-8 offset used to rescan the piece from byte 0 every call. This guards
    /// the fast-path cursor (`PieceTree.addBufferUTF8Offset`) against returning wrong bytes for
    /// the sequential access pattern it optimizes.
    func testAddBufferBytesInSequentialChunksMatchContiguous() throws {
        let text = makeLargeMixedContent()
        let pieceTreeView = StringView(string: text)
        XCTAssertTrue(pieceTreeView.usesPieceTree)
        let groundTruth = text as NSString
        var byteIndex = ByteCount(0)
        let chunkSize = ByteCount(4 * 1_024)
        var chunkCount = 0
        while byteIndex < pieceTreeView.byteCount {
            let end = min(byteIndex + chunkSize, pieceTreeView.byteCount)
            let range = ByteRange(from: byteIndex, to: end)
            try assertBytes(pieceTreeView, matches: groundTruth, in: range, chunk: chunkCount)
            byteIndex = end
            chunkCount += 1
        }
        XCTAssertGreaterThan(chunkCount, 10, "test fixture should require multiple chunks")
    }

    /// A non-monotonic access order (the cursor's fallback path: a different piece or a backward
    /// seek) must still resolve correctly, not just the common forward-scanning case.
    func testAddBufferBytesInReverseOrderMatchContiguous() throws {
        let text = makeLargeMixedContent()
        let pieceTreeView = StringView(string: text)
        let groundTruth = text as NSString
        let chunkSize = ByteCount(4 * 1_024)
        var ranges: [ByteRange] = []
        var byteIndex = ByteCount(0)
        while byteIndex < pieceTreeView.byteCount {
            let end = min(byteIndex + chunkSize, pieceTreeView.byteCount)
            ranges.append(ByteRange(from: byteIndex, to: end))
            byteIndex = end
        }
        for (index, range) in ranges.reversed().enumerated() {
            try assertBytes(pieceTreeView, matches: groundTruth, in: range, chunk: index)
        }
    }

    /// A forward scan populates the resume cursor; an edit afterwards must invalidate it so a
    /// later scan cannot resume from a position computed against the pre-edit buffer.
    func testAddBufferBytesAfterEditStillCorrect() throws {
        let text = makeLargeMixedContent()
        let pieceTreeView = StringView(string: text)
        let chunkSize = ByteCount(4 * 1_024)
        // Warm the forward cursor over the first half of the document.
        var byteIndex = ByteCount(0)
        let half = ByteCount(pieceTreeView.byteCount.value / 2)
        while byteIndex < half {
            let end = min(byteIndex + chunkSize, half)
            _ = pieceTreeView.bytes(in: ByteRange(from: byteIndex, to: end))
            byteIndex = end
        }
        pieceTreeView.replaceText(in: NSRange(location: 10, length: 5), with: "EDITED")
        let groundTruth = pieceTreeView.string
        byteIndex = ByteCount(0)
        while byteIndex < pieceTreeView.byteCount {
            let end = min(byteIndex + chunkSize, pieceTreeView.byteCount)
            try assertBytes(pieceTreeView, matches: groundTruth, in: ByteRange(from: byteIndex, to: end), chunk: 0)
            byteIndex = end
        }
    }

    /// Chunk boundaries that land mid-scalar (a 2-byte accented character) must still resolve to
    /// the correct UTF-8 offset, not an off-by-one from the resumed scan.
    func testAddBufferBytesAcrossMultibyteBoundary() throws {
        var text = String(repeating: "x", count: 300_000)
        // Sprinkle a 2-byte-UTF-8 scalar near every likely 4096-byte chunk boundary.
        for offset in stride(from: 4_000, to: text.count, by: 4_096) {
            let index = text.index(text.startIndex, offsetBy: min(offset, text.count - 1))
            text.replaceSubrange(index..<text.index(after: index), with: "é")
        }
        let pieceTreeView = StringView(string: text)
        XCTAssertTrue(pieceTreeView.usesPieceTree)
        let groundTruth = text as NSString
        var byteIndex = ByteCount(0)
        let chunkSize = ByteCount(4 * 1_024)
        while byteIndex < pieceTreeView.byteCount {
            let end = min(byteIndex + chunkSize, pieceTreeView.byteCount)
            try assertBytes(pieceTreeView, matches: groundTruth, in: ByteRange(from: byteIndex, to: end), chunk: 0)
            byteIndex = end
        }
    }

    private func makeLargeMixedContent() -> String {
        var lines: [String] = []
        var size = 0
        var i = 0
        // JS-shaped content (matches the real reader-callback consumer, TreeSitterParser), plus
        // occasional BMP multi-byte scalars so UTF-8/UTF-16 offset math is exercised too.
        while size < 300_000 {
            let line = i % 37 == 0
                ? "function fn\(i)(a, b) { const café = a + b; return café; }\n"
                : "function fn\(i)(a, b) { const x = a + b * \(i); return x; }\n"
            lines.append(line)
            size += line.utf8.count
            i += 1
        }
        return lines.joined()
    }

    /// Ground truth for a byte range: `NSString.getBytes` directly, independent of `StringView`'s
    /// piece-tree-vs-contiguous storage threshold (both `text as NSString` and a post-edit
    /// `StringView.string` are always exactly-`NSString`, never piece-tree-backed).
    private func assertBytes(_ view: StringView, matches groundTruth: NSString, in range: ByteRange, chunk: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let actual = view.bytes(in: range) else {
            return XCTFail("chunk \(chunk): expected bytes, got nil", file: file, line: line)
        }
        let nsRange = NSRange(location: range.location.utf16Length, length: range.length.utf16Length)
        var expectedLength = 0
        guard let expectedBuffer = groundTruth.getBytes(in: nsRange, encoding: String.preferredUTF16Encoding, usedLength: &expectedLength) else {
            return XCTFail("chunk \(chunk): expected getBytes to succeed", file: file, line: line)
        }
        XCTAssertEqual(actual.length.value, expectedLength, "chunk \(chunk): length mismatch", file: file, line: line)
        let actualData = Data(bytes: actual.bytes, count: actual.length.value)
        let expectedData = Data(bytes: expectedBuffer, count: expectedLength)
        if actualData != expectedData {
            let actualBytes = Array(actualData)
            let expectedBytes = Array(expectedData)
            var firstDiff = min(actualBytes.count, expectedBytes.count)
            for index in 0..<min(actualBytes.count, expectedBytes.count) where actualBytes[index] != expectedBytes[index] {
                firstDiff = index
                break
            }
            let lo = max(0, firstDiff - 8)
            let hi = min(actualBytes.count, firstDiff + 8)
            FileHandle.standardError.write("[assertBytes] chunk \(chunk) range=\(range) firstDiffAt=\(firstDiff)\n  actual=\(Array(actualBytes[lo..<hi]))\n  expect=\(Array(expectedBytes[lo..<hi]))\n".data(using: .utf8)!)
        }
        XCTAssertEqual(actualData, expectedData, "chunk \(chunk): byte content mismatch", file: file, line: line)
    }

    private func writeTemp(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func awaitLoad(_ url: URL) throws -> StringView {
        let box = BlockingBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let state = try await TextViewState.load(contentsOf: url)
                box.view = state.stringView
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error {
            throw error
        }
        return box.view!
    }
}

private func randomString(length: Int, alphabet: [Character], rng: inout SplitMix64) -> String {
    guard length > 0, !alphabet.isEmpty else {
        return ""
    }
    var result = ""
    result.reserveCapacity(length)
    for _ in 0..<length {
        let index = Int(rng.next(upperBound: UInt64(alphabet.count)))
        result.append(alphabet[index])
    }
    return result
}

private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func next(upperBound: UInt64) -> UInt64 {
        guard upperBound > 0 else {
            return 0
        }
        return next() % upperBound
    }
}

private final class BlockingBox: @unchecked Sendable {
    var view: StringView?
    var error: Error?
}
