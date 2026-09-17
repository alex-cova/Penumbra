import Foundation
@testable import Penumbra
import XCTest

final class StringHelpersTests: XCTestCase {
    func testByteCountOfLetter() {
        let str = "H"
        XCTAssertEqual(str.byteCount, 2)
    }

    func testByteCountOfMultipleLetter() {
        let str = "Hello"
        XCTAssertEqual(str.byteCount, 10)
    }

    func testByteCountOfEmoji() {
        let str = "🥳"
        XCTAssertEqual(str.byteCount, 4)
    }

    func testByteCountOfMultipleEmojis() {
        let str = "🥳🥳"
        XCTAssertEqual(str.byteCount, 8)
    }

    func testByteCountOfComposedEmoji() {
        let str = "👨‍👩‍👧‍👦"
        XCTAssertEqual(str.byteCount, 22)
    }
}
