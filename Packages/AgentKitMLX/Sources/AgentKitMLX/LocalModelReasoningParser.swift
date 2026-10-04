import Foundation

/// Splits a model's inline chain-of-thought (`<think>…</think>`) from its answer as the tokens
/// stream in. MLX hands us one undifferentiated `.chunk` stream, so the separation is ours.
///
/// Chunks are token-sized, so a tag routinely arrives split (`"<thi"` + `"nk>"`). Anything at the
/// end of the buffer that could still grow into a tag is held back until the next chunk decides
/// it — or `finish()` flushes it, so prose like `"2 < 3"` is never swallowed.
struct LocalModelReasoningParser: Sendable {
    enum Delta: Equatable, Sendable {
        case reasoning(String)
        case answer(String)
        /// A closing tag arrived with no opening tag, so everything emitted as `.answer` so far
        /// was really reasoning (the chat template put `<think>` in the *prompt*, as DeepSeek-R1
        /// distills and Qwen3 "Thinking" builds do). The consumer moves it across.
        case reclassifyAnswerAsReasoning
        /// A reasoning block closed (or the stream ended inside one).
        case reasoningEnded
    }

    private struct Candidate {
        let text: String
        let name: String
        let isClosing: Bool
    }

    private static let names = ["think", "reasoning"]

    private let allowsImplicitOpen: Bool
    private var buffer = ""
    /// The tag name of the block we're inside, `nil` while emitting the answer.
    private var openName: String?
    private var sawBlock = false
    /// Models pad tags with newlines (`<think>\n…\n</think>\n\n`); drop that padding at each seam.
    private var trimsLeadingWhitespace = false

    /// `allowsImplicitOpen` is off for the API path: recovering from a missing opening tag means
    /// retroactively unsending bytes, which a client that already received them can't do.
    init(allowsImplicitOpen: Bool = true) {
        self.allowsImplicitOpen = allowsImplicitOpen
    }

    mutating func consume(_ chunk: String) -> [Delta] {
        buffer += chunk
        return drain(isFinal: false)
    }

    /// Flushes any held-back partial tag as plain text and closes a still-open block.
    mutating func finish() -> [Delta] {
        var deltas = drain(isFinal: true)
        if openName != nil {
            openName = nil
            deltas.append(.reasoningEnded)
        }
        return deltas
    }

    // MARK: - Draining

    private mutating func drain(isFinal: Bool) -> [Delta] {
        var deltas: [Delta] = []
        while let (range, tag) = nextTag() {
            emit(String(buffer[..<range.lowerBound]), into: &deltas)
            buffer.removeSubrange(..<range.upperBound)
            handle(tag, into: &deltas)
        }
        let held = isFinal ? 0 : heldBackLength()
        let end = buffer.index(buffer.endIndex, offsetBy: -held)
        emit(String(buffer[..<end]), into: &deltas)
        buffer = String(buffer[end...])
        return deltas
    }

    private func candidates() -> [Candidate] {
        if let openName {
            // Inside a block only its own closing tag ends it; a repeated opener is swallowed.
            return [
                Candidate(text: "</\(openName)>", name: openName, isClosing: true),
                Candidate(text: "<\(openName)>", name: openName, isClosing: false),
            ]
        }
        return Self.names.flatMap { name in
            [
                Candidate(text: "<\(name)>", name: name, isClosing: false),
                Candidate(text: "</\(name)>", name: name, isClosing: true),
            ]
        }
    }

    private func nextTag() -> (Range<String.Index>, Candidate)? {
        var best: (Range<String.Index>, Candidate)?
        for candidate in candidates() {
            guard let range = buffer.range(of: candidate.text) else { continue }
            if best == nil || range.lowerBound < best!.0.lowerBound { best = (range, candidate) }
        }
        return best
    }

    /// The longest buffer suffix that is a proper prefix of some tag we're watching for.
    private func heldBackLength() -> Int {
        var longest = 0
        for candidate in candidates() {
            for length in stride(from: candidate.text.count - 1, to: longest, by: -1)
            where buffer.hasSuffix(String(candidate.text.prefix(length))) {
                longest = length
                break
            }
        }
        return longest
    }

    private mutating func handle(_ tag: Candidate, into deltas: inout [Delta]) {
        switch (tag.isClosing, openName) {
        case (false, nil):
            openName = tag.name
            sawBlock = true
            trimsLeadingWhitespace = true
        case (false, .some):
            break
        case (true, .some):
            openName = nil
            trimsLeadingWhitespace = true
            deltas.append(.reasoningEnded)
        case (true, nil):
            // A stray closer is always swallowed; only the first one, before any real block,
            // means "the opener lived in the prompt".
            if allowsImplicitOpen && !sawBlock {
                deltas.append(.reclassifyAnswerAsReasoning)
                deltas.append(.reasoningEnded)
            }
            sawBlock = true
            trimsLeadingWhitespace = true
        }
    }

    private mutating func emit(_ raw: String, into deltas: inout [Delta]) {
        var text = raw
        if trimsLeadingWhitespace {
            text = String(text.drop(while: \.isWhitespace))
            if !text.isEmpty { trimsLeadingWhitespace = false }
        }
        guard !text.isEmpty else { return }
        deltas.append(openName == nil ? .answer(text) : .reasoning(text))
    }
}
