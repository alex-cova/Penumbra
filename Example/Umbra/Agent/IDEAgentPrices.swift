import AgentKit
import Foundation

/// What a hosted model costs per million tokens, so the panel can show an estimate. Local models
/// and models the table doesn't know get no cost at all: a wrong number is worse than none.
///
/// The built-in rows are a starting point written down on 2026-10-04 and are not checked
/// against any provider's current price page; providers change prices, so Settings ▸ Agent holds
/// the table as editable text. The panel labels the figure an estimate.
struct IDEAgentPrices: Equatable {
    struct Entry: Equatable {
        var prefix: String
        /// US dollars per million tokens.
        var input: Double
        var cachedInput: Double
        var output: Double
    }

    var entries: [Entry]

    static let defaultText = """
    # model prefix, input, cached input, output (US dollars per million tokens)
    gpt-5 1.25 0.125 10.00
    gpt-4.1 2.00 0.50 8.00
    gpt-4o 2.50 1.25 10.00
    """

    static let `default` = IDEAgentPrices(text: defaultText)

    /// One entry per line: `prefix input cachedInput output`. `#` starts a comment; a line that
    /// doesn't parse is skipped.
    init(text: String) {
        entries = text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init)
            guard parts.count == 4, let input = Double(parts[1]), let cached = Double(parts[2]), let output = Double(parts[3]),
                  input >= 0, cached >= 0, output >= 0
            else { return nil }
            return Entry(prefix: parts[0].lowercased(), input: input, cachedInput: cached, output: output)
        }
    }

    init(entries: [Entry]) { self.entries = entries }

    /// The longest matching prefix wins, so `gpt-4o-mini` can have its own row beside `gpt-4o`.
    func entry(for model: String) -> Entry? {
        let name = model.lowercased()
        return entries.filter { name.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }
    }

    /// Dollars for one turn's usage. Cached tokens are part of the input count; reasoning tokens part of the output.
    func cost(of usage: TokenUsage, model: String) -> Double? {
        guard let entry = entry(for: model) else { return nil }
        let cached = min(usage.cachedInputTokens, usage.inputTokens)
        let fresh = usage.inputTokens - cached
        return (Double(fresh) * entry.input + Double(cached) * entry.cachedInput + Double(usage.outputTokens) * entry.output) / 1_000_000
    }

    static func format(_ dollars: Double) -> String {
        if dollars < 0.005 { return "<$0.01" }
        return "$" + String(format: dollars < 10 ? "%.2f" : "%.1f", dollars)
    }
}

/// What the host blob of a saved conversation holds: the transcript, and what it cost so far.
struct IDEAgentSavedTranscript: Codable {
    var entries: [IDEAgentPersistedEntry]
    /// `nil` when any turn had no known price; a total that leaves turns out would be misleading.
    var cost: Double?
    /// The model's checklist, which the history alone may no longer show after compaction.
    var todos: [TodoItem]?
}
