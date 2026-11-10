import XCTest
@testable import JavaIntelligence

/// The completion repair (`JavaCompletionRepair`) works on UTF-8 bytes and builds its result once. The
/// code it replaced, `NSString` and `String +` with a `Character`-based method-body check, is kept as
/// `ReferenceRepair`; everything here compares the two on generated text at every caret.
final class JavaRepairedTextEquivalenceTests: XCTestCase {
    // MARK: - Generated text

    /// A small deterministic generator, so a failure reproduces.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static let pieces = [
        "{", "}", "(", ")", ">", "->", " ", "  ", "\t", "\n", "\r\n", "\r", ";", "class X ", "void m() ", "else ", "foo", "bar.",
        "if (a) ", "\"{\"", "// }\n",
        // What the repair looks at: statements that end in `;` with a parenthesis open, `for` headers, strings and comments.
        "println(x.length(;\n", "foo(a, b);\n", "for (int i = 0;\n", "for(int i = 0;\n", "int x = 1;\n", "} else {\n", "void m() {\n",
        "class A {\n", "\"str(\"", "'(' ", "// c(;\n", "/* ; ( */", "a.b.", "call(\n", "x = \"a\\\"(\";\n",
        // Non-ASCII, and white space and ordinary characters outside ASCII right where `{` looks back for `)` or `>`.
        "\u{00A0}", "\u{2028}", "é", "😀", "\u{3000}", "\u{0085}", "\u{200A}", "\u{1680}", ") \u{00A0}", ")\u{3000}", ">\u{2028}", "ñ", "日", ")é"
    ]

    private func generatedText(_ generator: inout Generator, maxPieces: Int = 80) -> String {
        (0..<Int.random(in: 0...maxPieces, using: &generator)).map { _ in Self.pieces.randomElement(using: &generator)! }.joined()
    }

    /// Every UTF-16 offset that is not inside a surrogate pair (the editor never puts a caret there),
    /// with the matching UTF-8 offset.
    private func caretOffsets(_ text: String) -> [(utf16: Int, utf8: Int)] {
        var result: [(Int, Int)] = []
        var utf16 = 0
        var utf8 = 0
        for scalar in text.unicodeScalars {
            result.append((utf16, utf8))
            utf16 += scalar.value > 0xFFFF ? 2 : 1
            utf8 += String(scalar).utf8.count
        }
        result.append((utf16, utf8))
        return result
    }

    // MARK: - The repair as a whole

    func testRepairMatchesTheOriginalAtEveryCaret() {
        var generator = Generator(state: 0xFEED)
        var closed = 0
        var blanked = 0
        var bodiesClosed = 0
        for round in 0..<500 {
            let text = generatedText(&generator)
            for caret in caretOffsets(text) {
                let repaired = JavaCompletionRepair.repair(text, insertingDummyAtUTF16Offset: caret.utf16)
                let expected = ReferenceRepair.repairedText(text, insertingDummyAt: caret.utf16)
                XCTAssertEqual(repaired.text, expected, "round \(round) caret \(caret.utf16) in \(text.debugDescription)")
                XCTAssertEqual(repaired.caretByteOffset, caret.utf8, "caret byte offset, round \(round) caret \(caret.utf16)")
                XCTAssertTrue(repaired.reachedRequestedOffset)
                if expected.contains(");__penumbra__") || expected.hasSuffix(";") { closed += 1 }
                if repaired.text.utf8.count == expected.utf8.count, expected.contains("+") { blanked += 1 }
                if expected.contains(";}") { bodiesClosed += 1 }
            }
        }
        XCTAssertGreaterThan(closed, 100, "too few cases that close the statement for this to mean much")
        XCTAssertGreaterThan(blanked, 100, "too few cases with a blanked parenthesis for this to mean much")
        XCTAssertGreaterThan(bodiesClosed, 20, "too few cases that close a lambda or body brace for this to mean much (\(bodiesClosed))")
    }

    func testOffsetsOutsideTheTextAreClamped() {
        var generator = Generator(state: 0xC1A3)
        for _ in 0..<200 {
            let text = generatedText(&generator, maxPieces: 30)
            let length = text.utf16.count
            for offset in [-5, 0, length, length + 1, length + 40] {
                let repaired = JavaCompletionRepair.repair(text, insertingDummyAtUTF16Offset: offset)
                XCTAssertEqual(repaired.text, ReferenceRepair.repairedText(text, insertingDummyAt: offset), "offset \(offset) in \(text.debugDescription)")
                XCTAssertEqual(repaired.reachedRequestedOffset, offset <= length, "offset \(offset) of \(length)")
                XCTAssertEqual(repaired.caretByteOffset, offset <= 0 ? 0 : (offset >= length ? text.utf8.count : repaired.caretByteOffset))
            }
        }
    }

    func testEmptyAndTinyDocuments() {
        for text in ["", " ", "\n", "\r\n", ";", "(", "é", "😀"] {
            for caret in caretOffsets(text) {
                XCTAssertEqual(
                    JavaCompletionRepair.repair(text, insertingDummyAtUTF16Offset: caret.utf16).text,
                    ReferenceRepair.repairedText(text, insertingDummyAt: caret.utf16), "\(text.debugDescription) at \(caret.utf16)"
                )
            }
        }
    }

    /// The statement-completion cases people actually hit, spelled out.
    func testTheRepairsAreWhatTheyAreMeantToBe() {
        let dummy = JavaCompletionProvider.dummyIdentifier
        func repaired(_ before: String, _ after: String = "") -> String {
            JavaCompletionRepair.repair(before + after, insertingDummyAtUTF16Offset: before.utf16.count).text
        }
        // At the end of a line inside a method, a `;` closes the statement.
        XCTAssertEqual(repaired("class A { void m() {\n  products."), "class A { void m() {\n  products.\(dummy);")
        // An open parenthesis on the line is closed first.
        XCTAssertEqual(repaired("class A { void m() {\n  if (a instanceof B b && b."), "class A { void m() {\n  if (a instanceof B b && b.\(dummy));")
        // A lambda block (or a class or method body) opened inside a call that is still open on the line is
        // closed before the call's `)`, innermost first; each brace gets `;}` so the statement under the caret ends.
        let open = "class A { void m() {\n  "
        XCTAssertEqual(repaired(open + "build(s, (l, v) -> { if (l."), open + "build(s, (l, v) -> { if (l.\(dummy));});")
        XCTAssertEqual(repaired(open + "pipe(\"x\", s -> s.length(), n -> { n."), open + "pipe(\"x\", s -> s.length(), n -> { n.\(dummy);});")
        XCTAssertEqual(
            repaired(open + "users.forEach(u -> { u.getRoles().forEach(r -> { r."),
            open + "users.forEach(u -> { u.getRoles().forEach(r -> { r.\(dummy);});});"
        )
        XCTAssertEqual(
            repaired(open + "foo(new Runnable() { public void run() { x."), open + "foo(new Runnable() { public void run() { x.\(dummy);};});"
        )
        // CRLF line endings and non-ASCII text on the caret's line do not change what is closed.
        XCTAssertEqual(
            repaired("// é日本😀\r\nclass A { void m() {\r\n  build(\"é日本😀\", (l, v) -> { l."),
            "// é日本😀\r\nclass A { void m() {\r\n  build(\"é日本😀\", (l, v) -> { l.\(dummy);});"
        )
        // What stays as it was: a block that stands on its own, a brace that is not a body, brackets in
        // literals, and a lambda block already closed on the line.
        XCTAssertEqual(repaired(open + "if (a) { foo(x."), open + "if (a) { foo(x.\(dummy));")
        XCTAssertEqual(repaired(open + "for (int i = 0; i < n; i++) { foo."), open + "for (int i = 0; i < n; i++) { foo.\(dummy);")
        XCTAssertEqual(repaired(open + "foo(new int[] {1, x."), open + "foo(new int[] {1, x.\(dummy));")
        XCTAssertEqual(repaired(open + "foo(\"{\", x."), open + "foo(\"{\", x.\(dummy));")
        XCTAssertEqual(repaired(open + "foo('{', x."), open + "foo('{', x.\(dummy));")
        XCTAssertEqual(repaired(open + "foo(x -> { a(); }, y."), open + "foo(x -> { a(); }, y.\(dummy));")
        // Not inside a method body (a member declaration), and not at the end of the line: nothing extra.
        XCTAssertEqual(repaired("class A {\n  private Str"), "class A {\n  private Str\(dummy)")
        XCTAssertEqual(repaired("class A { void m() {\n  foo.", "bar\n}}"), "class A { void m() {\n  foo.\(dummy)bar\n}}")
        // An earlier broken statement has its open parentheses blanked.
        XCTAssertEqual(repaired("void m() {\n  println(x.length(;\n  it"), "void m() {\n  println+x.length+;\n  it\(dummy);")
        // Non-ASCII text and CRLF before the caret.
        XCTAssertEqual(repaired("// é日本😀\r\nclass A { void m() {\r\n  x."), "// é日本😀\r\nclass A { void m() {\r\n  x.\(dummy);")
    }

    // MARK: - The pieces

    private func oldRestOfLineIsBlank(_ text: String, utf16Offset: Int) -> Bool {
        let ns = text as NSString
        let rest = ns.substring(from: utf16Offset).prefix { $0 != "\n" && $0 != "\r\n" }
        return rest.allSatisfy { $0 == " " || $0 == "\t" }
    }

    func testPredicatesMatchTheCharacterBasedOriginals() {
        var generator = Generator(state: 0x5EED)
        for _ in 0..<600 {
            let text = generatedText(&generator)
            for caret in caretOffsets(text) {
                let ns = text as NSString
                let prefix = ns.substring(to: caret.utf16)
                var copy = text
                copy.withUTF8 { bytes in
                    XCTAssertEqual(
                        JavaCompletionRepair.restOfLineIsBlank(bytes, from: caret.utf8), oldRestOfLineIsBlank(text, utf16Offset: caret.utf16),
                        "restOfLineIsBlank at \(caret.utf16) in \(text.debugDescription)"
                    )
                    XCTAssertEqual(
                        JavaCompletionRepair.isInsideMethodBody(bytes, before: caret.utf8), ReferenceRepair.isInsideMethodBody(prefix),
                        "isInsideMethodBody at \(caret.utf16) in \(text.debugDescription)"
                    )
                }
            }
        }
    }

    /// The scan reads eight bytes at a time; a long prefix that crosses many words must agree too.
    func testLargePrefixCrossingWordBoundaries() {
        var generator = Generator(state: 0xC0FFEE)
        var text = ""
        while text.utf16.count < 20_000 { text += generatedText(&generator) }
        let ns = text as NSString
        for caret in caretOffsets(text).enumerated().filter({ $0.offset % 997 == 0 }).map(\.element) {
            var copy = text
            copy.withUTF8 { bytes in
                XCTAssertEqual(
                    JavaCompletionRepair.isInsideMethodBody(bytes, before: caret.utf8), ReferenceRepair.isInsideMethodBody(ns.substring(to: caret.utf16)),
                    "at \(caret.utf16)"
                )
            }
        }
    }

    // MARK: - Offsets

    func testUTF8OffsetsMatchTheStandardLibrary() {
        var generator = Generator(state: 0x0FF5)
        for _ in 0..<400 {
            let text = generatedText(&generator)
            let offsets = caretOffsets(text)
            var copy = text
            copy.withUTF8 { bytes in
                for caret in offsets {
                    XCTAssertEqual(JavaUTF8Offsets.byteOffset(forUTF16Offset: caret.utf16, in: bytes), caret.utf8, "UTF-16 \(caret.utf16) in \(text.debugDescription)")
                    // Going back from a caret by k units lands on the caret k units earlier, when that is a scalar boundary.
                    for earlier in offsets where earlier.utf16 <= caret.utf16 && caret.utf16 - earlier.utf16 <= 6 {
                        XCTAssertEqual(
                            JavaUTF8Offsets.byteOffset(movingBackUTF16Units: caret.utf16 - earlier.utf16, from: caret.utf8, in: bytes), earlier.utf8,
                            "back \(caret.utf16 - earlier.utf16) from \(caret.utf16) in \(text.debugDescription)"
                        )
                    }
                }
                XCTAssertEqual(JavaUTF8Offsets.byteOffset(forUTF16Offset: 1_000_000, in: bytes), bytes.count)
                XCTAssertEqual(JavaUTF8Offsets.byteOffset(forUTF16Offset: -4, in: bytes), 0)
            }
        }
    }

    /// Long ASCII runs are skipped 32 bytes at a time; a non-ASCII scalar in or just after a run, and a
    /// target on either side of a block, are where that goes wrong.
    func testUTF8OffsetsAcrossLongRunsAndBlockEdges() {
        var generator = Generator(state: 0xB10C)
        for _ in 0..<60 {
            var text = ""
            for _ in 0..<Int.random(in: 1...12, using: &generator) {
                text += String(repeating: "a", count: Int.random(in: 0...90, using: &generator))
                text += ["é", "日", "😀", "\n", "{"].randomElement(using: &generator)!
            }
            let offsets = caretOffsets(text)
            var copy = text
            copy.withUTF8 { bytes in
                for caret in offsets {
                    XCTAssertEqual(JavaUTF8Offsets.byteOffset(forUTF16Offset: caret.utf16, in: bytes), caret.utf8, "UTF-16 \(caret.utf16)")
                }
            }
        }
    }

    func testAnOffsetInsideASurrogatePairStopsAtTheScalar() {
        var text = "a😀b"
        text.withUTF8 { bytes in
            XCTAssertEqual(JavaUTF8Offsets.byteOffset(forUTF16Offset: 1, in: bytes), 1)
            XCTAssertEqual(JavaUTF8Offsets.byteOffset(forUTF16Offset: 2, in: bytes), 1, "between the two halves: before the scalar")
            XCTAssertEqual(JavaUTF8Offsets.byteOffset(forUTF16Offset: 3, in: bytes), 5)
            XCTAssertEqual(JavaUTF8Offsets.byteOffset(movingBackUTF16Units: 1, from: 5, in: bytes), 5, "one unit back would split the pair")
            XCTAssertEqual(JavaUTF8Offsets.byteOffset(movingBackUTF16Units: 2, from: 5, in: bytes), 1)
        }
    }

    /// An offset between `\r` and `\n` is not on a `Character` boundary, and `samePosition(in:)` used to
    /// make the helper answer "end of the text" for it.
    func testByteOffsetBetweenCarriageReturnAndLineFeed() {
        let text = "ab\r\ncd é😀x"
        for (utf16, bytes) in [(0, 0), (2, 2), (3, 3), (4, 4), (6, 6), (7, 7), (8, 9), (10, 13), (11, 14)] {
            XCTAssertEqual(JavaCompletionProvider.utf8ByteOffset(forUTF16Offset: utf16, in: text), bytes, "UTF-16 offset \(utf16)")
        }
        XCTAssertEqual(JavaCompletionProvider.utf8ByteOffset(forUTF16Offset: 999, in: text), text.utf8.count, "past the end")
        XCTAssertEqual(JavaCompletionProvider.utf8ByteOffset(forUTF16Offset: -1, in: text), 0)
    }
}
