import Foundation

/// Ends a turn at the first literal end-of-turn special token in the model's text.
///
/// Some local models (a template whose EOS is not in the model's stop list, a base model behind an
/// instruct template) emit `<|endoftext|>` or `<|im_end|>` as ordinary text and keep going, writing
/// the next `Human:` turn themselves and even calling tools in it. Everything from the marker on is
/// dropped and `stopped` is set, so the caller can end generation. Only `<|…|>` tokens are matched:
/// they do not occur in source code or prose, unlike `</s>`.
///
/// Markers can arrive split across chunks, so the tail of the text that could still become a marker
/// is held back until the next chunk decides it.
struct StopMarkerFilter {
    static let markers = [
        "<|endoftext|>", "<|im_end|>", "<|im_start|>", "<|eot_id|>", "<|eom_id|>", "<|end_of_text|>", "<|end|>",
    ]

    private(set) var stopped = false
    private var held = ""

    /// The text that is safe to show now.
    mutating func consume(_ text: String) -> String {
        guard !stopped else { return "" }
        held += text
        let cut = Self.markers.compactMap { held.range(of: $0)?.lowerBound }.min()
        if let cut {
            stopped = true
            defer { held = "" }
            return String(held[..<cut])
        }
        let keep = Self.longestMarkerPrefixSuffix(of: held)
        let emit = String(held.dropLast(keep))
        held = String(held.suffix(keep))
        return emit
    }

    /// What was held back when the stream ended without a marker (a lone `<|` is just text).
    mutating func finish() -> String {
        defer { held = "" }
        return stopped ? "" : held
    }

    /// The length of the longest suffix of `text` that is a proper prefix of a marker.
    private static func longestMarkerPrefixSuffix(of text: String) -> Int {
        let longest = markers.map(\.count).max() ?? 0
        var best = 0
        for marker in markers {
            let limit = min(marker.count - 1, text.count, longest)
            guard limit > best else { continue }
            for length in stride(from: limit, to: best, by: -1) where text.hasSuffix(marker.prefix(length)) {
                best = length
                break
            }
        }
        return best
    }
}
