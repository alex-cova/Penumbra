import Foundation

/// Ends a turn at the first literal end-of-turn special token, or at an invented user turn, in the
/// model's text.
///
/// Some local models (a template whose EOS is not in the model's stop list, a base model behind an
/// instruct template) emit `<|endoftext|>` or `<|im_end|>` as ordinary text and keep going, writing
/// the next `Human:` turn themselves and even calling tools in it. Small models also role-play both
/// sides with no special token at all, as plain `User:` / `Assistant:` line headers. Everything from
/// the marker or header on is dropped and `stopped` is set, so the caller can end generation. Only
/// `<|…|>` tokens are matched as markers: they do not occur in source code or prose, unlike `</s>`.
/// A `User:` / `Human:` header counts only at the start of a line, so prose that mentions a user
/// mid-line passes.
///
/// Markers and headers can arrive split across chunks, so the tail of the text that could still become
/// one is held back until the next chunk decides it.
///
/// Matching runs on unicode scalars, not `Character`s: `\r\n` is a single `Character`, so a
/// `Character` search for `\nUser:` would never see a CRLF line start.
struct StopMarkerFilter {
    static let markers = [
        "<|endoftext|>", "<|im_end|>", "<|im_start|>", "<|eot_id|>", "<|eom_id|>", "<|end_of_text|>", "<|end|>",
    ]
    /// Line-start role headers. The leading newline is what makes them line-start only.
    static let turnHeaders = ["\nUser:", "\nHuman:"]

    private static let stops: [[Unicode.Scalar]] = (markers + turnHeaders).map { Array($0.unicodeScalars) }
    private static let newline: Unicode.Scalar = "\n"
    private static let carriageReturn: Unicode.Scalar = "\r"

    private(set) var stopped = false
    private var held: [Unicode.Scalar] = []
    /// True until text has been shown, so a header opening the turn counts as line-start.
    private var atTurnStart = true

    /// The text that is safe to show now.
    mutating func consume(_ text: String) -> String {
        guard !stopped else { return "" }
        held += text.unicodeScalars
        let virtualNewline: [Unicode.Scalar] = atTurnStart ? [Self.newline] : []
        let scan = virtualNewline + held
        if let cut = Self.firstStop(in: scan) {
            stopped = true
            defer { held = [] }
            return Self.string(held.prefix(max(0, cut - virtualNewline.count)))
        }
        let keep = min(Self.heldTail(of: scan), held.count)
        let emit = Self.string(held.dropLast(keep))
        held = Array(held.suffix(keep))
        if !emit.isEmpty { atTurnStart = false }
        return emit
    }

    /// What was held back when the stream ended without a marker (a lone `<|` is just text).
    mutating func finish() -> String {
        defer { held = [] }
        return stopped ? "" : Self.string(held)
    }

    private static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    /// Where the earliest marker or header starts in `scan`. A header's leading `\n` takes the `\r`
    /// before it along, so a CRLF line break is dropped whole.
    private static func firstStop(in scan: [Unicode.Scalar]) -> Int? {
        for start in scan.indices {
            for stop in stops where scan[start...].starts(with: stop) {
                let crlf = stop[0] == newline && start > 0 && scan[start - 1] == carriageReturn
                return crlf ? start - 1 : start
            }
        }
        return nil
    }

    /// The length of the longest suffix of `scan` that could still become a marker or header: a proper
    /// prefix of one, or a lone `\r` that a following `\n` would turn into a header's line break.
    private static func heldTail(of scan: [Unicode.Scalar]) -> Int {
        var best = scan.last == carriageReturn ? 1 : 0
        for stop in stops {
            let limit = min(stop.count - 1, scan.count)
            guard limit > best else { continue }
            for length in stride(from: limit, to: best, by: -1) where scan.suffix(length).elementsEqual(stop.prefix(length)) {
                best = length
                break
            }
        }
        return best
    }
}
