import Foundation
@testable import Penumbra
import XCTest

final class StringViewTests: XCTestCase {
    func testStringEquality() {
        let str = "Hello world"
        let stringView = StringView(string: str)
        XCTAssertEqual(stringView.string, "Hello world")
    }

    func testPassingValidRangeToSubstring() {
        let str = "Hello world"
        let stringView = StringView(string: str)
        let range = NSRange(location: 6, length: 5)
        XCTAssertEqual(stringView.substring(in: range), "world")
    }

    func testPassingInvalidRangeToSubstring() {
        let str = "Hello world"
        let stringView = StringView(string: str)
        let range = NSRange(location: 8, length: 5)
        XCTAssertNil(stringView.substring(in: range))
    }

    func testPassingValidIndexToCharacterAt() {
        let str = "Hello world"
        let stringView = StringView(string: str)
        XCTAssertEqual(stringView.character(at: 4), "o")
    }

    func testPassingInvalidIndexToCharacterAt() {
        let str = "Hello world"
        let stringView = StringView(string: str)
        XCTAssertNil(stringView.character(at: 12))
    }

    func testGetCharacterFromEmojiString() {
        // Should return nil because the first character in a composed glyph isn't a valid Unicode.Scalar.
        let str = "🥳🥳"
        let stringView = StringView(string: str)
        XCTAssertNil(stringView.character(at: 0))
    }

    func testGetBytesOfFirstCharacter() {
        let str = "Hello world"
        let stringView = StringView(string: str)
        let byteRange = ByteRange(location: 0, length: 2)
        let bytes = stringView.bytes(in: byteRange)!
        XCTAssertEqual(string(from: bytes), "H")
    }

    func testGetBytesOfTwoFirstCharacters() {
        let str = "Hello world"
        let stringView = StringView(string: str)
        let byteRange = ByteRange(location: 0, length: 4)
        let bytes = stringView.bytes(in: byteRange)!
        XCTAssertEqual(string(from: bytes), "He")
    }

    func testGetBytesOfSecondCharacter() {
        let str = "Hello world"
        let stringView = StringView(string: str)
        let byteRange = ByteRange(location: 2, length: 2)
        let bytes = stringView.bytes(in: byteRange)!
        XCTAssertEqual(string(from: bytes), "e")
    }

    func testGetBytesOfEntireString() {
        let str = "Hello world"
        let stringView = StringView(string: str)
        let byteRange = ByteRange(location: 0, length: str.byteCount)
        let bytes = stringView.bytes(in: byteRange)!
        XCTAssertEqual(string(from: bytes), "Hello world")
    }

    func testGetBytesOfEmoji() {
        let str = "🥳"
        let stringView = StringView(string: str)
        let byteRange = ByteRange(location: 0, length: 4)
        let bytes = stringView.bytes(in: byteRange)!
        XCTAssertEqual(string(from: bytes), "🥳")
    }

    func testGetBytesOfTwoEmojis() {
        let str = "🥳🥳"
        let stringView = StringView(string: str)
        let byteRange = ByteRange(location: 0, length: 8)
        let bytes = stringView.bytes(in: byteRange)!
        XCTAssertEqual(string(from: bytes), "🥳🥳")
    }

    func testGetBytesOfSecondEmoji() {
        let str = "🥳🥳"
        let stringView = StringView(string: str)
        let byteRange = ByteRange(location: 4, length: 4)
        let bytes = stringView.bytes(in: byteRange)!
        XCTAssertEqual(string(from: bytes), "🥳")
    }

    func testGetBytesOfComposedEmoji() {
        let str = "👨‍👩‍👧‍👦"
        let stringView = StringView(string: str)
        let byteRange = ByteRange(location: 0, length: 22)
        let bytes = stringView.bytes(in: byteRange)!
        XCTAssertEqual(string(from: bytes), "👨‍👩‍👧‍👦")
    }

    func testSmallUntitledBuffersStayContiguous() {
        let stringView = StringView(string: "Hello world")
        XCTAssertFalse(stringView.usesPieceTree)
        XCTAssertFalse(stringView.isFileBacked)
    }

    func testLargeUntitledBuffersUseAPieceTreeWithoutFileMapping() {
        let text = String(repeating: "a", count: StringView.pieceTreeUntitledThreshold)
        let stringView = StringView(string: text)
        XCTAssertTrue(stringView.usesPieceTree)
        XCTAssertFalse(stringView.isFileBacked)
        XCTAssertGreaterThan(stringView.pieceCount, 1)
        stringView.replaceText(in: NSRange(location: 0, length: 0), with: "X")
        XCTAssertEqual(stringView.substring(in: NSRange(location: 0, length: 2)), "Xa")
        XCTAssertEqual(stringView.length, text.utf16.count + 1)
    }

    func testAssigningALargeStringPromotesToPieceTree() {
        let stringView = StringView(string: "small")
        XCTAssertFalse(stringView.usesPieceTree)
        stringView.string = String(repeating: "b", count: StringView.pieceTreeUntitledThreshold) as NSString
        XCTAssertTrue(stringView.usesPieceTree)
        XCTAssertFalse(stringView.isFileBacked)
    }

    /// Enumerates a copy made under the lock; ranges must still come back in document
    /// coordinates, forward and reverse, for both storage kinds (bracket matching relies on it).
    func testEnumerateSubstringsReportsDocumentRanges() {
        let small = "ab(c😀d)e"
        let large = String(repeating: "x", count: StringView.pieceTreeUntitledThreshold) + small
        for text in [small, large] {
            let stringView = StringView(string: text)
            let offset = (text as NSString).length - (small as NSString).length
            let range = NSRange(location: offset + 2, length: 6)
            var forward: [(String, NSRange)] = []
            stringView.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { substring, substringRange, _, _ in
                forward.append((substring ?? "", substringRange))
            }
            XCTAssertEqual(forward.map(\.0), ["(", "c", "😀", "d", ")"], "usesPieceTree=\(stringView.usesPieceTree)")
            XCTAssertEqual(forward[2].1, NSRange(location: offset + 4, length: 2))
            XCTAssertEqual(forward[4].1, NSRange(location: offset + 7, length: 1))

            var reverseFirst: NSRange?
            stringView.enumerateSubstrings(in: range, options: [.byComposedCharacterSequences, .reverse]) { _, substringRange, _, stop in
                reverseFirst = substringRange
                stop.pointee = true
            }
            XCTAssertEqual(reverseFirst, NSRange(location: offset + 7, length: 1))
        }
    }

    /// A background parse reads through `bytes(in:)` while the main thread edits and asks for
    /// composed-character ranges (Backspace). Those reads used to skip the lock, race the piece
    /// tree's lookup cache and crash in `PieceTree.nodeContaining`. Run under TSan to see races.
    func testConcurrentByteReadsDuringEditsAndComposedCharacterQueries() {
        let line = "public int value = 42; // café 😀\n"
        let text = String(repeating: line, count: StringView.pieceTreeUntitledThreshold / line.utf16.count + 1)
        let stringView = StringView(string: text)
        XCTAssertTrue(stringView.usesPieceTree)
        let stop = ManagedAtomicFlag()
        let reader = Thread {
            var offset = 0
            while !stop.isSet {
                let length = stringView.length
                guard length > 64 else { continue }
                offset = (offset + 997) % (length - 64)
                _ = stringView.bytes(in: ByteRange(location: ByteCount(offset * 2), length: ByteCount(128)))
            }
            stop.markFinished()
        }
        reader.start()
        let lineCount = text.utf16.count / line.utf16.count
        for iteration in 0 ..< 600 {
            // Line starts only: the UTF-8 piece tree can't split the emoji's surrogate pair.
            let location = (iteration * 131) % lineCount * line.utf16.count
            _ = stringView.rangeOfComposedCharacterSequence(at: location)
            _ = stringView.rangeOfComposedCharacterSequences(for: NSRange(location: location, length: 1))
            stringView.prefetch(utf16Range: NSRange(location: location, length: 64))
            stringView.replaceText(in: NSRange(location: location, length: 0), with: "\n")
            stringView.replaceText(in: NSRange(location: location, length: 1), with: "")
        }
        stop.set()
        stop.waitUntilFinished()
        XCTAssertEqual(stringView.string as String, text)
    }
}

private extension StringViewTests {
    private func string(from result: StringViewBytesResult) -> String {
        let data = Data(bytes: result.bytes, count: result.length.value)
        return String(data: data, encoding: String.preferredUTF16Encoding)!
    }
}

/// Stop flag plus completion signal shared with the reader thread in the concurrency test.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func set() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func markFinished() {
        finished.signal()
    }

    func waitUntilFinished() {
        finished.wait()
    }
}
