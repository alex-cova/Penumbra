import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

enum IDEAgentFormat {
    /// "1.2K" for 1_234; whole numbers below a thousand.
    static func tokens(_ count: Int) -> String {
        count < 1_000 ? "\(count)" : String(format: "%.1fK", Double(count) / 1_000)
    }

    /// A user's message as typed, with a leading `/command` in bold and `@file` mentions marked.
    static func userMessage(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        func mark(_ range: NSRange) {
            guard let swiftRange = Range(range, in: text), let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result)
            else { return }
            result[lower..<upper].foregroundColor = IDEAppearance.ColorToken.accent
        }
        if text.hasPrefix("/"), let end = text.firstIndex(where: \.isWhitespace) ?? Optional(text.endIndex) {
            mark(NSRange(text.startIndex..<end, in: text))
        }
        for token in IDEAgentMentionToken.scan(text) { mark(token.range) }
        return result
    }

    /// Inline Markdown with line breaks kept; plain text if it doesn't parse.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
