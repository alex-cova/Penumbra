import AgentKit
import Foundation

/// Redacts credential-shaped text from tool output before it reaches the history. Runs as the
/// session's `shapeToolOutput`, so secrets never land in `items`, `SessionStore` or a summary; the
/// `.toolCallFinished` event still carries the original for the live transcript. Deterministic for
/// a given input, so prefix caching is unaffected. Command and web output are scrubbed, since those
/// echo the outside world; file reads and edits pass through.
nonisolated enum IDEAgentOutputScrubber {
    static let replacement = "[redacted]"

    /// AWS access keys, GitHub tokens, `sk-` keys, PEM private-key blocks.
    private static let patterns = [
        #"AKIA[0-9A-Z]{16}"#,
        #"ghp_[A-Za-z0-9]{36,}"#,
        #"sk-(proj-)?[A-Za-z0-9\-_]{20,}"#,
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
    ]

    static func scrub(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }

    static func shape(_ input: ToolOutputShapingInput) -> String {
        guard input.risk == .command || input.toolName == "web_search" else { return input.text }
        return scrub(input.text)
    }
}
