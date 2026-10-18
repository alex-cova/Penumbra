import Foundation

/// Something only the host application can do, named by an id the provider and the host agree on
/// (Run, Debug and so on). The editor passes it back to the host when the action is chosen.
public struct CodeActionCommand: Sendable, Hashable {
    public let id: String
    public let arguments: [String]

    public init(id: String, arguments: [String] = []) {
        self.id = id
        self.arguments = arguments
    }
}

/// A secondary command shown beside a code action, such as disabling an intention.
public struct CodeActionOption: Sendable, Hashable {
    public let title: String
    public let command: CodeActionCommand

    public init(title: String, command: CodeActionCommand) {
        self.title = title
        self.command = command
    }
}

/// A single actionable fix or refactor offered at a cursor position.
public struct CodeAction: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let kind: String?
    public let edits: [TextEdit]
    public let isPreferred: Bool
    /// What the host does when the action is chosen, after `edits` (usually none) are applied.
    public let command: CodeActionCommand?
    /// The lines the action would write, shown beside it in the menu. Nil hides the preview.
    public let preview: String?
    /// Commands offered from a chevron on the row (Disable, Edit settings).
    public let options: [CodeActionOption]

    public init(
        id: UUID = UUID(),
        title: String,
        kind: String? = nil,
        edits: [TextEdit],
        isPreferred: Bool = false,
        command: CodeActionCommand? = nil,
        preview: String? = nil,
        options: [CodeActionOption] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.edits = edits
        self.isPreferred = isPreferred
        self.command = command
        self.preview = preview
        self.options = options
    }
}
