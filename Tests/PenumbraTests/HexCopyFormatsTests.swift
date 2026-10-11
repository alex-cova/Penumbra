import Foundation
import HexKit
import XCTest

final class HexCopyFormatsTests: XCTestCase {
    func testCopyStyles() {
        let bytes: [UInt8] = [0x4D, 0x5A, 0x90]
        XCTAssertEqual(HexCopy.format(bytes, style: .hex), "4D 5A 90")
        XCTAssertEqual(HexCopy.format(bytes, style: .prefixed), "0x4D, 0x5A, 0x90")
        XCTAssertEqual(HexCopy.format(bytes, style: .cArray), "unsigned char bytes[] = { 0x4D, 0x5A, 0x90 };")
        XCTAssertEqual(HexCopy.format(bytes, style: .swift), "[0x4D, 0x5A, 0x90]")
        XCTAssertEqual(HexCopy.format(bytes, style: .base64), Data(bytes).base64EncodedString())
        XCTAssertEqual(HexCopy.format([0x41, 0x00, 0x42], style: .ascii), "A.B")
        let dumped = HexCopy.format(Array("MZ".utf8), style: .hexdump)
        XCTAssertTrue(dumped.hasPrefix("00000000  4d 5a"))
        XCTAssertTrue(dumped.contains("|MZ|"))
        XCTAssertTrue(dumped.hasSuffix("00000002"))
    }

    func testPasteParser() {
        XCTAssertEqual(HexCopy.parsePaste("4D 5A 90"), [0x4D, 0x5A, 0x90])
        XCTAssertEqual(HexCopy.parsePaste("0x4D, 0x5A, 0x90"), [0x4D, 0x5A, 0x90])
        XCTAssertEqual(HexCopy.parsePaste("0x4"), [0x04])
        XCTAssertEqual(HexCopy.parsePaste("abcd"), [0xAB, 0xCD])
        XCTAssertEqual(HexCopy.parsePaste("hello"), Array("hello".utf8))
        XCTAssertEqual(HexCopy.parsePaste("Hello"), Array("Hello".utf8))
        XCTAssertEqual(HexCopy.parsePaste(""), [])
        XCTAssertEqual(HexCopy.parsePaste("{0x4D, 0x5A};"), [0x4D, 0x5A])
        XCTAssertEqual(HexCopy.format([0x68, 0x65, 0x6C, 0x6C, 0x6F], style: .hexdump).contains("|hello|"), true)
    }

    func testPaneEncodingsRoundTripPrintableBytes() {
        let encodings: [HexPaneEncoding] = [.ascii, .latin1, .macRoman, .cp437, .windows1252]
        for encoding in encodings {
            let glyph = encoding.glyph(for: 0x41)
            XCTAssertEqual(glyph, "A")
            XCTAssertEqual(encoding.byte(for: glyph), 0x41)
            XCTAssertEqual(encoding.glyph(for: 0x00), "·")
            XCTAssertNil(encoding.byte(for: "😀"))
        }
        XCTAssertEqual(HexPaneEncoding.latin1.byte(for: "é"), 0xE9)
        XCTAssertNil(HexPaneEncoding.ascii.byte(for: "é"))
        XCTAssertEqual(HexLayout.autoBytesPerRow(contentWidth: 10, charWidth: 8, groupSize: 8, offsetDigits: 8), 8)
        XCTAssertEqual(HexLayout.autoBytesPerRow(contentWidth: 10_000, charWidth: 7, groupSize: 8, offsetDigits: 8), 64)
    }
}
