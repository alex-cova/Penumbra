import Foundation
import XCTest
@testable import SubprocessKit

final class UTF8ChunkDecoderTests: XCTestCase {
    func testACharacterSplitAcrossReadsIsDecodedWhole() {
        let bytes = Array("a€😀b".utf8)  // 1 + 3 + 4 + 1 bytes
        for split in 1..<bytes.count {
            var decoder = UTF8ChunkDecoder()
            let text = decoder.feed(Data(bytes[..<split])) + decoder.feed(Data(bytes[split...])) + decoder.finish()
            XCTAssertEqual(text, "a€😀b", "split at \(split)")
        }
    }

    func testOneByteAtATime() {
        var decoder = UTF8ChunkDecoder()
        var text = ""
        for byte in "héllo 😀".utf8 { text += decoder.feed(Data([byte])) }
        XCTAssertEqual(text + decoder.finish(), "héllo 😀")
    }

    func testAnEmptyChunkIsHarmless() {
        var decoder = UTF8ChunkDecoder()
        XCTAssertEqual(decoder.feed(Data()), "")
        XCTAssertEqual(decoder.finish(), "")
    }
}
