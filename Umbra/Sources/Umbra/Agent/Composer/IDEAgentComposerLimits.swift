import Foundation

/// How long a message may be before the composer warns. A warning only: the message still sends, as in
/// t3code (`ComposerPromptLengthValidation`). The count is UTF-16 units, which is constant time on a native
/// string, so the check costs nothing per keystroke even on a pasted log.
enum IDEAgentComposerLimits {
    static let maxPromptCharacters = 100_000

    /// The warning under the field, or nil when the message is within the limit.
    static func validationMessage(for text: String, limit: Int = maxPromptCharacters) -> String? {
        let count = text.utf16.count
        guard count > limit else { return nil }
        let format = IntegerFormatStyle<Int>.number
        return "This message is \(count.formatted(format)) characters, over the \(limit.formatted(format)) suggested. "
            + "It will still be sent, but a long paste fills the model's context fast; attach the file with @ instead."
    }
}
