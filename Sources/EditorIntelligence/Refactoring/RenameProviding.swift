import Foundation

/// The symbol under the caret that a rename would change.
public struct RenameTarget: Sendable {
    /// The identifier's range in the requesting document.
    public let range: TextRange
    public let currentName: String
    /// What is being renamed, for the prompt title ("class", "method"…).
    public let kindDescription: String?
    /// Returns a user-facing problem for an unacceptable new name, or `nil` when it is fine.
    /// Providers override this with their language's identifier rules.
    public let validate: @Sendable (String) -> String?

    public init(
        range: TextRange,
        currentName: String,
        kindDescription: String? = nil,
        validate: @escaping @Sendable (String) -> String? = RenameTarget.validateIdentifier
    ) {
        self.range = range
        self.currentName = currentName
        self.kindDescription = kindDescription
        self.validate = validate
    }

    /// Default rule: non-empty, starts with a letter, `_` or `$`, continues with letters, digits,
    /// `_` or `$`.
    @Sendable
    public static func validateIdentifier(_ name: String) -> String? {
        guard let first = name.unicodeScalars.first else { return "Enter a name" }
        func isStart(_ s: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(s) || s == "_" || s == "$" }
        guard isStart(first) else { return "A name must start with a letter, _ or $" }
        for scalar in name.unicodeScalars.dropFirst() where !(isStart(scalar) || CharacterSet.decimalDigits.contains(scalar)) {
            return "“\(String(scalar))” isn't allowed in a name"
        }
        return nil
    }
}

/// One occurrence a rename would change.
public struct RenamePlanEntry: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let range: TextRange
    public let oldText: String
    public let newText: String
    /// The full text of the line, for the preview.
    public let lineText: String
    /// The provider could not pin this occurrence to the renamed symbol; shown unchecked.
    public let isAmbiguous: Bool
    /// In a file that must not be edited (generated sources, JARs); shown disabled.
    public let isReadOnly: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        range: TextRange,
        oldText: String,
        newText: String,
        lineText: String,
        isAmbiguous: Bool = false,
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.url = url
        self.range = range
        self.oldText = oldText
        self.newText = newText
        self.lineText = lineText
        self.isAmbiguous = isAmbiguous
        self.isReadOnly = isReadOnly
    }

    /// Whether the entry is applied unless the user changes it.
    public var isSelectedByDefault: Bool { !isAmbiguous && !isReadOnly }
}

/// What a rename would do, for preview before anything is edited.
public struct RenamePlan: Sendable {
    public var entries: [RenamePlanEntry]
    public var fileRenames: [(from: URL, to: URL)]
    public var warnings: [String]
    /// Set when the rename must not proceed ("overrides a library method", invalid name…).
    public var blockingError: String?

    public init(
        entries: [RenamePlanEntry] = [],
        fileRenames: [(from: URL, to: URL)] = [],
        warnings: [String] = [],
        blockingError: String? = nil
    ) {
        self.entries = entries
        self.fileRenames = fileRenames
        self.warnings = warnings
        self.blockingError = blockingError
    }

    public var isBlocked: Bool { blockingError != nil }

    /// The workspace edit for the entries in `selection` (default: those selected by default).
    /// Read-only entries are never included.
    public func workspaceEdit(including selection: Set<RenamePlanEntry.ID>? = nil) -> WorkspaceEdit {
        var changes: [URL: [TextEdit]] = [:]
        for entry in entries where !entry.isReadOnly {
            let included = selection.map { $0.contains(entry.id) } ?? entry.isSelectedByDefault
            guard included else { continue }
            changes[entry.url, default: []].append(TextEdit(range: entry.range, replacement: entry.newText))
        }
        return WorkspaceEdit(changes: changes, fileRenames: fileRenames, warnings: warnings)
    }
}

/// Language-specific rename. The controller drives `prepareRename` → name prompt → `rename` →
/// preview; the host applies the resulting ``WorkspaceEdit``.
public protocol RenameProviding: Sendable {
    /// The symbol at the context's caret, or `nil` when nothing there can be renamed.
    func prepareRename(_ context: NavigationContext) async -> RenameTarget?
    /// Everything a rename to `newName` would change. Problems that forbid the rename are reported
    /// through ``RenamePlan/blockingError``; throw only for unexpected failures.
    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan
}
