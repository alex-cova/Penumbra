import Foundation

/// One text change a workspace edit plan would apply.
public struct WorkspaceEditPlanEntry: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let range: TextRange
    public let oldText: String
    public let newText: String
    /// The full text of the line, for the preview.
    public let lineText: String
    /// Optional label shown in the preview ("insert declaration", "replace expression"…).
    public let description: String?
    /// The provider could not pin this occurrence; shown unchecked.
    public let isAmbiguous: Bool
    /// In a file that must not be edited; shown disabled.
    public let isReadOnly: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        range: TextRange,
        oldText: String,
        newText: String,
        lineText: String,
        description: String? = nil,
        isAmbiguous: Bool = false,
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.url = url
        self.range = range
        self.oldText = oldText
        self.newText = newText
        self.lineText = lineText
        self.description = description
        self.isAmbiguous = isAmbiguous
        self.isReadOnly = isReadOnly
    }

    /// Whether the entry is applied unless the user changes it.
    public var isSelectedByDefault: Bool { !isAmbiguous && !isReadOnly }
}

/// What a multi-file edit would do, for preview before anything is changed.
public struct WorkspaceEditPlan: Sendable {
    public var entries: [WorkspaceEditPlanEntry]
    public var fileRenames: [(from: URL, to: URL)]
    public var fileDeletions: [URL]
    public var warnings: [String]
    /// Set when the edit must not proceed.
    public var blockingError: String?
    /// Preview sheet title; `nil` means rename-style copy.
    public var title: String?

    public init(
        entries: [WorkspaceEditPlanEntry] = [],
        fileRenames: [(from: URL, to: URL)] = [],
        fileDeletions: [URL] = [],
        warnings: [String] = [],
        blockingError: String? = nil,
        title: String? = nil
    ) {
        self.entries = entries
        self.fileRenames = fileRenames
        self.fileDeletions = fileDeletions
        self.warnings = warnings
        self.blockingError = blockingError
        self.title = title
    }

    public var isBlocked: Bool { blockingError != nil }

    /// The workspace edit for the entries in `selection` (default: those selected by default).
    /// Read-only entries are never included.
    public func workspaceEdit(including selection: Set<WorkspaceEditPlanEntry.ID>? = nil) -> WorkspaceEdit {
        var changes: [URL: [TextEdit]] = [:]
        for entry in entries where !entry.isReadOnly {
            let included = selection.map { $0.contains(entry.id) } ?? entry.isSelectedByDefault
            guard included else { continue }
            changes[entry.url, default: []].append(TextEdit(range: entry.range, replacement: entry.newText))
        }
        return WorkspaceEdit(changes: changes, fileRenames: fileRenames, fileDeletions: fileDeletions, warnings: warnings)
    }
}

public typealias RenamePlanEntry = WorkspaceEditPlanEntry
public typealias RenamePlan = WorkspaceEditPlan
