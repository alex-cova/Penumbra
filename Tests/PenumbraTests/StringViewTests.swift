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
}

private extension StringViewTests {
    private func string(from result: StringViewBytesResult) -> String {
        let data = Data(bytes: result.bytes, count: result.length.value)
        return String(data: data, encoding: String.preferredUTF16Encoding)!
    }
}
