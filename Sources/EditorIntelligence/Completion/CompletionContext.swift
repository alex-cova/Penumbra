import Foundation

/// Context passed to completion providers.
public struct CompletionContext: Sendable, CustomStringConvertible {
    public let document: Document
    public let cursor: Cursor
    public let trigger: RequestTrigger
    public let prefix: String
    public let range: TextRange
    /// How many times completion was invoked in a row without the popup closing: 2 for a
    /// second Ctrl+Space, which asks providers for a broader result (IntelliJ's "all classes,
    /// not only the imported ones").
    public let invocationCount: Int

    public init(
        document: Document,
        cursor: Cursor,
        trigger: RequestTrigger,
        prefix: String,
        range: TextRange,
        invocationCount: Int = 1
    ) {
        self.document = document
        self.cursor = cursor
        self.trigger = trigger
        self.prefix = prefix
        self.range = range
        self.invocationCount = invocationCount
    }

    /// The character just before the prefix is a member-access `.` (or `::`).
    public var isMemberAccess: Bool {
        let start = range.start.utf16Offset
        guard start > 0 else { return false }
        let before = document.substring(utf16Offset: start - 1, length: 1)
        return before == "." || (before == ":" && start > 1 && document.substring(utf16Offset: start - 2, length: 1) == ":")
    }

    public var description: String {
        "Completion in \(document.displayName) at \(cursor.position) prefix='\(prefix)'"
    }
}
