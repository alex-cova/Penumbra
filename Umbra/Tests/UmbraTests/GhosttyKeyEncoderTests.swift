import XCTest
@testable import Umbra

/// Headless tests for `GhosttyKeystrokeEncoder` (plan Step 4): NSEvent-level
/// keyCodes + text in, VT bytes out. Assertions pin legacy xterm encodings
/// under default terminal modes.
final class GhosttyKeyEncoderTests: XCTestCase {
    private func encoder(optionAsMeta: Bool = true) -> (GhosttyVtTerminal, GhosttyKeystrokeEncoder) {
        let term = GhosttyVtTerminal(cols: 80, rows: 24)!
        let enc = GhosttyKeystrokeEncoder()!
        term.withTerminal { enc.syncToTerminal($0, optionAsMeta: optionAsMeta) }
        return (term, enc)
    }

    private func encode(
        _ enc: GhosttyKeystrokeEncoder,
        _ term: GhosttyVtTerminal,
        keyCode: UInt16,
        text: String,
        modifiers: GhosttyModifiers = [],
        unshifted: String? = nil,
        isRepeat: Bool = false
    ) -> Data? {
        term.withTerminal { _ in
            enc.encode(GhosttyKeystroke(
                keyCode: keyCode,
                modifiers: modifiers,
                text: text,
                unshiftedText: unshifted,
                isRepeat: isRepeat))
        }
    }

    func testPrintableKey() {
        let (term, enc) = encoder()
        XCTAssertEqual(encode(enc, term, keyCode: 0x00, text: "a"), Data("a".utf8))
    }

    func testShiftedKey() {
        let (term, enc) = encoder()
        XCTAssertEqual(
            encode(enc, term, keyCode: 0x00, text: "A", unshifted: "a"),
            Data("A".utf8))
    }

    func testEnterTabBackspaceEscape() {
        let (term, enc) = encoder()
        XCTAssertEqual(encode(enc, term, keyCode: 0x24, text: "\r"), Data("\r".utf8))
        XCTAssertEqual(encode(enc, term, keyCode: 0x30, text: "\t"), Data("\t".utf8))
        XCTAssertEqual(encode(enc, term, keyCode: 0x33, text: "\u{7F}"), Data("\u{7F}".utf8))
        XCTAssertEqual(encode(enc, term, keyCode: 0x35, text: "\u{1B}"), Data("\u{1B}".utf8))
    }

    func testArrowsAndFunctionKeys() {
        let (term, enc) = encoder()
        XCTAssertEqual(encode(enc, term, keyCode: 0x7E, text: ""), Data("\u{1B}[A".utf8))
        XCTAssertEqual(encode(enc, term, keyCode: 0x7B, text: ""), Data("\u{1B}[D".utf8))
        XCTAssertEqual(encode(enc, term, keyCode: 0x7A, text: ""), Data("\u{1B}OP".utf8))
        XCTAssertEqual(encode(enc, term, keyCode: 0x78, text: ""), Data("\u{1B}OQ".utf8))
        XCTAssertEqual(encode(enc, term, keyCode: 0x77, text: ""), Data("\u{1B}[F".utf8))
        XCTAssertEqual(encode(enc, term, keyCode: 0x73, text: ""), Data("\u{1B}[H".utf8))
        XCTAssertEqual(encode(enc, term, keyCode: 0x75, text: ""), Data("\u{1B}[3~".utf8))
    }

    func testCtrlC() {
        let (term, enc) = encoder()
        XCTAssertEqual(
            encode(enc, term, keyCode: 0x08, text: "\u{3}", modifiers: .control),
            Data("\u{3}".utf8))
    }

    func testOptionAsMetaPrefixesEscape() {
        let (term, enc) = encoder(optionAsMeta: true)
        XCTAssertEqual(
            encode(enc, term, keyCode: 0x00, text: "a", modifiers: .alt),
            Data("\u{1B}a".utf8))
    }

    func testOptionWithoutMetaPassesThrough() {
        let (term, enc) = encoder(optionAsMeta: false)
        XCTAssertEqual(
            encode(enc, term, keyCode: 0x00, text: "a", modifiers: .alt),
            Data("a".utf8))
    }

    func testRepeatEncodesLikePress() {
        let (term, enc) = encoder()
        XCTAssertEqual(
            encode(enc, term, keyCode: 0x00, text: "a", isRepeat: true),
            Data("a".utf8))
    }

    func testLoneModifierProducesNoOutput() {
        let (term, enc) = encoder()
        XCTAssertNil(encode(enc, term, keyCode: 0x38, text: ""))
    }

    func testApplicationCursorKeysFollowMode() {
        let (term, enc) = encoder()
        term.write(Data("\u{1B}[?1h".utf8)) // DECCKM: application cursor keys
        term.withTerminal { enc.syncToTerminal($0, optionAsMeta: true) }
        XCTAssertEqual(
            encode(enc, term, keyCode: 0x7E, text: ""),
            Data("\u{1B}OA".utf8))
    }
}
