import AppKit
import XCTest
@testable import Penumbra

/// F11. `LineTypesetter` used to rebuild a `CTLine` per dropped character when a suggested break
/// overhung the width, and the word-wrap lookback built an attributed substring, a `String` and a
/// `CharacterSet` per character. These tests hold the fragments to what that code produced.
final class LineTypesetterTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font])
    }

    private func typeset(_ text: String, width: CGFloat, mode: LineBreakMode) -> (fragments: [LineFragment], created: Int) {
        let typesetter = LineTypesetter(lineID: "test")
        typesetter.lineBreakMode = mode
        typesetter.constrainingWidth = width
        typesetter.reset()
        typesetter.prepareToTypeset(attributed(text))
        let fragments = typesetter.typesetLineFragments(toLocation: text.utf16.count)
        return (fragments, typesetter.createdLineCount)
    }

    // MARK: Reference: the code this replaced, with its slow per-character helpers

    private func referenceIsWhitespace(_ string: NSAttributedString, at location: Int) -> Bool {
        guard location < string.length else { return false }
        let substring = string.attributedSubstring(from: NSRange(location: location, length: 1)).string
        return CharacterSet.whitespaces.containsAllCharacters(of: substring)
    }

    private func referencePrefersBreak(_ string: NSAttributedString, at location: Int) -> Bool {
        let substring = string.attributedSubstring(from: NSRange(location: location, length: 1)).string
        let trimmed = substring.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || CharacterSet(charactersIn: trimmed).isSubset(of: .punctuationCharacters)
    }

    private func referenceSuggest(
        _ string: NSAttributedString,
        _ typesetter: CTTypesetter,
        start: Int,
        width: CGFloat,
        mode: LineBreakMode
    ) -> Int {
        if mode == .byCharWrapping {
            return CharacterLineBreakSuggester(typesetter: typesetter, attributedString: string, constrainingWidth: width)
                .suggestLineBreak(startingAt: start)
        }
        let length = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
        guard start + length < string.length else { return length }
        if referencePrefersBreak(string, at: start + length - 1) { return length }
        let maximumLookback = min(length, 100)
        var lookback = 0
        var found = false
        while lookback < maximumLookback && !found {
            if referencePrefersBreak(string, at: start + length - lookback) { found = true } else { lookback += 1 }
        }
        return found ? length - (lookback - 1) : length
    }

    private func reference(_ text: String, width: CGFloat, mode: LineBreakMode) -> [NSRange] {
        referenceFragments(text, width: width, mode: mode).map { NSRange(location: $0.visible.location, length: $0.visible.length + $0.hidden) }
    }

    private func referenceFragments(_ text: String, width: CGFloat, mode: LineBreakMode) -> [(visible: NSRange, hidden: Int)] {
        let string = attributed(text)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var ranges: [(visible: NSRange, hidden: Int)] = []
        var start = 0
        while start < string.length {
            var length = referenceSuggest(string, typesetter, start: start, width: width, mode: mode)
            var fragmentWidth = CGFloat.infinity
            while length > 0 && fragmentWidth > width {
                let line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, length))
                fragmentWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                length -= 1
            }
            guard fragmentWidth.isFinite else { break }
            var hidden = 0
            if start + length < string.length - 1 {
                var next = start + length + 1
                while referenceIsWhitespace(string, at: next) { next += 1; hidden += 1 }
            }
            let fragmentLength = length + 1
            ranges.append((NSRange(location: start, length: fragmentLength), hidden))
            start += fragmentLength + hidden
        }
        return ranges
    }

    // MARK: Tests

    private func fixtures() -> [(String, CGFloat)] {
        var generator = SeededGenerator(seed: 42)
        let alphabet = Array("ab cd_ef.gh,\t\t  (x)日本語😀é\u{0301}-/=+\"'")
        var cases: [(String, CGFloat)] = [
            (String(repeating: "abcdefghij", count: 400), 800),
            (String(repeating: "let value = compute(a, b, c) + fallback(); ", count: 120), 10_000),
            (String(repeating: "function(a,b){return a+b;};", count: 150), 600),
            (String(repeating: " ", count: 2000) + "tail text here", 800),
            ((0 ..< 12).map { _ in "word" + String(repeating: " ", count: 300) }.joined(), 800),
            (String(repeating: "\t", count: 200) + "x", 500),
            (String(repeating: "日本語", count: 300), 700),
            (String(repeating: "😀", count: 300), 600),
            ("https://example.com/" + String(repeating: "path/segment-", count: 80), 640),
            ("a   b" + String(repeating: " ", count: 150) + "c", 90)
        ]
        for _ in 0 ..< 40 {
            let length = Int.random(in: 1 ... 600, using: &generator)
            let text = String((0 ..< length).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)] })
            cases.append((text, CGFloat(Int.random(in: 40 ... 900, using: &generator))))
        }
        return cases
    }

    func testFragmentsMatchTheLinearSearchTheyReplaced() {
        for (index, (text, width)) in fixtures().enumerated() {
            for mode in [LineBreakMode.byWordWrapping, .byCharWrapping] {
                let expected = referenceFragments(text, width: width, mode: mode)
                let actual = typeset(text, width: width, mode: mode).fragments
                let label = "fixture \(index) (\(text.utf16.count) chars, width \(width), \(mode))"
                XCTAssertEqual(actual.map(\.visibleRange), expected.map(\.visible), label)
                XCTAssertEqual(actual.map(\.hiddenLength), expected.map(\.hidden), label)
            }
        }
    }

    /// 2,000 spaces then a word: the suggested break overhangs, and the old search dropped one
    /// character at a time (1,903 `CTLine`s for two fragments).
    func testALongRunOfSpacesDoesNotBuildALinePerCharacter() {
        let text = String(repeating: " ", count: 2000) + "tail text here"
        let (fragments, created) = typeset(text, width: 800, mode: .byWordWrapping)
        XCTAssertEqual(fragments.count, 2)
        XCTAssertLessThanOrEqual(created, 25, "built \(created) lines for \(fragments.count) fragments")
    }

    func testOrdinaryTextBuildsOneLinePerFragment() {
        let text = String(repeating: "abcdefghij", count: 1000)
        let (fragments, created) = typeset(text, width: 800, mode: .byWordWrapping)
        XCTAssertGreaterThan(fragments.count, 50)
        XCTAssertEqual(created, fragments.count)
    }

    func testTheHelpersAgreeWithTheSubstringVersionsOnEveryUnit() {
        let text = " \t\u{00A0}\u{3000}a.,;!?-_()[]{}\"'«»、。日😀\u{0301}\n\r\u{2028}x"
        let string = attributed(text)
        for location in 0 ..< string.length {
            XCTAssertEqual(string.isWhitespaceCharacter(at: location), referenceIsWhitespace(string, at: location), "whitespace at \(location)")
            XCTAssertEqual(string.prefersLineBreak(after: location), referencePrefersBreak(string, at: location), "break at \(location)")
        }
        XCTAssertFalse(string.isWhitespaceCharacter(at: string.length))
        XCTAssertFalse(string.isWhitespaceCharacter(at: -1))
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
