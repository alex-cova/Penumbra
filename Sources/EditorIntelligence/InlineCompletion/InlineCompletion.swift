import Foundation

/// One inline (ghost text) completion request. `prefix`/`suffix` are the bounded window
/// around the caret the model sees, not the whole document.
public struct InlineCompletionRequest: Sendable {
    public var filePath: String?
    public var languageID: String?
    public var prefix: String
    public var suffix: String
    public var maxLines: Int
    public var maxTokens: Int
    public var stop: [String]

    public init(
        filePath: String? = nil, languageID: String? = nil, prefix: String, suffix: String,
        maxLines: Int = 1, maxTokens: Int = 48, stop: [String] = []
    ) {
        self.filePath = filePath
        self.languageID = languageID
        self.prefix = prefix
        self.suffix = suffix
        self.maxLines = maxLines
        self.maxTokens = maxTokens
        self.stop = stop
    }

    /// The line the caret is on, before the caret.
    public var currentLinePrefix: String {
        self.prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? prefix
    }

    /// The line the caret is on, after the caret.
    public var currentLineSuffix: String {
        suffix.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? suffix
    }

    /// The line above the caret's, trimmed; a suggestion that only repeats it is dropped.
    public var previousLine: String {
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return "" }
        return lines[lines.count - 2].trimmingCharacters(in: .whitespaces)
    }

    /// Indentation of the caret's line.
    public var indentation: String {
        String(currentLinePrefix.prefix { $0 == " " || $0 == "\t" })
    }
}

/// A suggestion ready to show: the text to insert at the caret, plus edits that come with
/// accepting it (an auto-import).
public struct InlineSuggestion: Sendable, Equatable {
    public var text: String
    public var additionalEdits: [TextEdit]

    public init(text: String, additionalEdits: [TextEdit] = []) {
        self.text = text
        self.additionalEdits = additionalEdits
    }

    /// First line and any extra lines, for the multi-line presentation.
    public var lines: [String] {
        text.components(separatedBy: "\n")
    }
}

/// A source of inline suggestions: a local model, an LSP, a test fake.
public protocol InlineCompletionModel: Sendable {
    func complete(_ request: InlineCompletionRequest) -> AsyncThrowingStream<String, Error>
}

/// Per-language check of a suggestion before it is shown. It may truncate the suggestion
/// or add `additionalEdits` (auto-import), and returns `nil` to show nothing.
public protocol InlineCompletionValidating: Sendable {
    func validate(
        _ suggestion: InlineSuggestion, in document: Document, at position: TextPosition
    ) async -> InlineSuggestion?
}
