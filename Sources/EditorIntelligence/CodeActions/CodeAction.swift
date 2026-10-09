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

/// A single actionable fix or refactor offered at a cursor position.
public struct CodeAction: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let kind: String?
    public let edits: [TextEdit]
    public let isPreferred: Bool
    /// What the host does when the action is chosen, after `edits` (usually none) are applied.
    public let command: CodeActionCommand?

    public init(
        id: UUID = UUID(),
        title: String,
        kind: String? = nil,
        edits: [TextEdit],
        isPreferred: Bool = false,
        command: CodeActionCommand? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.edits = edits
        self.isPreferred = isPreferred
        self.command = command
    }
}
