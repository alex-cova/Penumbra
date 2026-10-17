import Foundation

/// Basic completion (Ctrl+Space) versus smart type (Ctrl+Shift+Space).
public enum CompletionMode: Hashable, Sendable {
    case basic
    case smart
}

/// Context passed to completion providers.
public struct CompletionContext: Sendable, CustomStringConvertible {
    public let document: Document
    public let cursor: Cursor
    public let trigger: RequestTrigger
    public let prefix: String
    public let range: TextRange
    /// IntelliJ's invocation count. `0` is an autopopup while typing. `1` is the first explicit
    /// Ctrl+Space. `2` or more is a repeated explicit completion (non-imported classes, inaccessible
    /// members) once the popup has been noticeable.
    public let invocationCount: Int
    public let mode: CompletionMode
    /// `.templates` asks for postfix or live templates only (⌘J, and the postfix expansion key).
    public let filter: Filter
    /// Set when the request is a command-completion request, or a regular one that should
    /// carry a command section.
    public let commandMode: CommandMode?

    /// How command completion was triggered.
    public enum CommandMode: Hashable, Sendable {
        /// `..` after an expression or block: commands only.
        case dotDot
        /// A single `.`: regular items, with a command section last.
        case singleDot
        /// A `.` typed in a read-only file: navigation commands only, filtered virtually.
        case readOnly
    }

    /// Which suggestions a provider should return.
    public enum Filter: Hashable, Sendable {
        /// The site's ordinary suggestions.
        case all
        /// Postfix templates when a receiver precedes the caret, live templates otherwise.
        case templates
    }

    public init(
        document: Document,
        cursor: Cursor,
        trigger: RequestTrigger,
        prefix: String,
        range: TextRange,
        invocationCount: Int = 1,
        mode: CompletionMode = .basic,
        filter: Filter = .all,
        commandMode: CommandMode? = nil
    ) {
        self.document = document
        self.cursor = cursor
        self.trigger = trigger
        self.prefix = prefix
        self.range = range
        self.invocationCount = invocationCount
        self.mode = mode
        self.filter = filter
        self.commandMode = commandMode
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
