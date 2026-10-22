import Foundation

/// Notices a model stuck repeating one short unit (`ACHI ACHI ACHI …`) so the caller can end the turn
/// instead of letting it run to `maxTokens`.
///
/// A repetition penalty only nudges the logits; a small, confident model can repeat straight through it.
/// This is the backstop. The text must end in a run of one unit of up to `maxPeriod` characters, long
/// enough (`minSpan` characters and `minRepeats` repeats) that prose and code do not reach it. A unit
/// longer than `shortPeriod` (a whole sentence or line, as in a model answering `hi` with one question
/// over and over) needs only `minLongRepeats` repeats, since exact copies of that much text are rarer. A unit
/// made only of whitespace and rule characters (a `=====` rule, indentation, blank lines) never counts;
/// other punctuation such as `'` does.
///
/// Only a bounded tail of the text is kept, so the work per chunk does not grow with the answer.
struct RepetitionLoopDetector {
    static let maxPeriod = 200
    static let shortPeriod = 32
    static let minRepeats = 10
    static let minLongRepeats = 5
    static let minSpan = 80
    /// Holds the longest run that can trip: `maxPeriod * minLongRepeats`, with room to spare.
    private static let window = 1_200

    private(set) var tripped = false
    private var tail: [Character] = []

    /// Whether the text so far ends in a loop.
    mutating func consume(_ text: String) -> Bool {
        guard !tripped else { return true }
        tail.append(contentsOf: text)
        if tail.count > Self.window { tail.removeFirst(tail.count - Self.window) }
        tripped = Self.endsInLoop(tail)
        return tripped
    }

    /// Whitespace and the characters of a rule or table border (`=====`, `-----`, `|---|`): legitimate
    /// at any length. Anything else repeated (`'''''`, `ACHI`) is a loop.
    private static func isLayout(_ character: Character) -> Bool {
        character.isWhitespace || "-=_*#~+|.".contains(character)
    }

    private static func endsInLoop(_ text: [Character]) -> Bool {
        for period in 1...maxPeriod {
            let repeats = period <= shortPeriod ? minRepeats : minLongRepeats
            let span = max(minSpan, period * repeats)
            guard text.count >= span else { continue }
            let start = text.count - span
            var periodic = true
            for index in (start + period)..<text.count where text[index] != text[index - period] {
                periodic = false
                break
            }
            if periodic, text[(text.count - period)...].contains(where: { !isLayout($0) }) {
                return true
            }
        }
        return false
    }
}
