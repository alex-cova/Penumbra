import Foundation

/// Bounds text the user did not write, so a payload cannot close the block it sits in or imitate an
/// editor note. Used for attachments, commands the user ran, and web search. Tool output from
/// `read_file` and `grep` is not wrapped: that would spend tokens on every call, and the system
/// prompt already says tool text is data.
public enum UntrustedContent {
    public static let editorNotePrefix = "[Note from the editor, not from the user]"

    /// `<untrusted source="…">…</untrusted>`, with lookalike closers and editor notes disarmed inside.
    public static func wrap(_ text: String, source: String) -> String {
        "<untrusted source=\"\(safeSource(source))\">\n\(defang(text))\n</untrusted>"
    }

    /// Closing tags of this wrapper and of `<attachment>`, in any case and with spaces inside the
    /// brackets, plus lines that imitate the editor's note prefix.
    public static func defang(_ text: String) -> String {
        let ns = text as NSString
        var tags = ""
        var cursor = 0
        for match in closingTags.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range
            tags += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            tags += "< /\(name)>"
            cursor = range.location + range.length
        }
        tags += ns.substring(from: cursor)
        return tags.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.lowercased().hasPrefix("[note from the editor") else { return String(line) }
            var copy = String(line)
            if let bracket = copy.firstIndex(of: "[") { copy.replaceSubrange(bracket...bracket, with: "(") }
            return copy
        }.joined(separator: "\n")
    }

    private static let closingTags = try! NSRegularExpression(
        pattern: #"<\s*/\s*(untrusted|attachment)\s*>"#, options: [.caseInsensitive])

    private static func safeSource(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// The part of a user message the person typed. Editor notes, the editor-state block, attachments
/// and shell output are context the editor added; a compaction keeps the typed words and summarizes
/// the rest.
public enum UserText {
    public static let editorStateEnd = "[End editor state]"
    public static let attachmentLead = "[Attached by the user with @ mentions."
    public static let legacyShellEnd = "[End of the commands the user ran.]"

    /// `nil` when the message is an editor note or a compaction summary, not something the user typed.
    public static func typed(_ text: String) -> String? {
        if text.hasPrefix(ConversationSummary.heading) { return nil }
        if text.hasPrefix(UntrustedContent.editorNotePrefix) || text.hasPrefix("[Note from the editor") { return nil }
        var body = text
        if let end = body.range(of: editorStateEnd) { body = String(body[end.upperBound...]) }
        if let end = body.range(of: legacyShellEnd) { body = String(body[end.upperBound...]) }
        body = droppingLeadingUntrusted(body)
        if let lead = body.range(of: attachmentLead) { body = String(body[..<lead.lowerBound]) }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A message that opens with one `<untrusted>…</untrusted>` block (commands the user ran).
    private static func droppingLeadingUntrusted(_ text: String) -> String {
        let trimmed = text.drop(while: { $0 == " " || $0 == "\n" })
        guard trimmed.lowercased().hasPrefix("<untrusted") else { return text }
        guard let close = trimmed.range(of: "</untrusted>", options: .caseInsensitive) else { return text }
        return String(trimmed[close.upperBound...])
    }
}
