import Foundation

/// Runs one inline completion at a time: debounces, cancels the stale request, formats
/// and filters the model's text, then lets the language validator check it. Nothing here
/// is awaited on a keystroke; callers fire and forget, and drop results whose anchor moved.
public actor InlineCompletionEngine {
    private let model: any InlineCompletionModel
    private let validator: (any InlineCompletionValidating)?
    public let debounceInterval: TimeInterval
    public nonisolated let filter = InlineCompletionFilter()
    private var generation = 0
    private var currentTask: Task<InlineSuggestion?, Never>?

    public init(
        model: any InlineCompletionModel,
        validator: (any InlineCompletionValidating)? = nil,
        debounceInterval: TimeInterval = 0.15
    ) {
        self.model = model
        self.validator = validator
        self.debounceInterval = debounceInterval
    }

    /// The bounded window the model sees: at most ~6 KB before the caret and ~1.5 KB after,
    /// cut on UTF-16 boundaries through the document's range reader, never a full copy made
    /// just for completion.
    public static func window(in document: Document, at position: TextPosition) -> (prefix: String, suffix: String) {
        let offset = position.utf16Offset
        let total = document.contentSnapshot.utf16Length
        let prefixStart = max(0, offset - 6_144)
        let suffixEnd = min(total, offset + 1_536)
        return (
            document.substring(utf16Offset: prefixStart, length: offset - prefixStart),
            document.substring(utf16Offset: offset, length: suffixEnd - offset)
        )
    }

    /// A suggestion for `request`, or `nil` when there is nothing worth showing, the
    /// request was superseded, or validation rejected it. `request.prefix`/`suffix` are
    /// replaced by the bounded window read from `document`.
    public func suggest(
        request: InlineCompletionRequest, document: Document, position: TextPosition
    ) async -> InlineSuggestion? {
        generation += 1
        let mine = generation
        currentTask?.cancel()
        let task = Task { () -> InlineSuggestion? in
            if debounceInterval > 0 {
                try? await Task.sleep(for: .seconds(debounceInterval))
            }
            guard !Task.isCancelled else { return nil }
            let window = Self.window(in: document, at: position)
            var bounded = request
            bounded.prefix = window.prefix
            bounded.suffix = window.suffix
            var raw = ""
            do {
                for try await delta in model.complete(bounded) {
                    if Task.isCancelled { return nil }
                    raw += delta
                }
            } catch {
                return nil
            }
            guard !Task.isCancelled,
                  let formatted = InlineSuggestionFormatter.format(
                      raw, suffixLine: bounded.currentLineSuffix, maxLines: bounded.maxLines,
                      indentation: bounded.indentation),
                  filter.accepts(formatted, for: bounded) else { return nil }
            var suggestion = InlineSuggestion(text: formatted)
            if let validator {
                guard let validated = await validator.validate(suggestion, in: document, at: position) else {
                    return nil
                }
                suggestion = validated
                guard filter.accepts(suggestion.text, for: bounded) else { return nil }
            }
            return suggestion
        }
        currentTask = task
        let result = await task.value
        guard mine == generation else { return nil }
        return result
    }

    public func cancel() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
    }
}
