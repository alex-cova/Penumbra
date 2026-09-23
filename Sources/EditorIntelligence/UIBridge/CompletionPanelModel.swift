import Foundation

/// Presentation model for a completion panel.
public struct CompletionPanelModel: Sendable, Identifiable, CustomStringConvertible {
    public let id: UUID
    public let items: [CompletionItem]
    public let selectedIndex: Int?
    public let replacementRange: TextRange
    /// The typed prefix the items were filtered by; its matched characters are drawn in bold.
    public let prefix: String
    /// Shown instead of rows when `items` is empty, e.g. "No suggestions".
    public let emptyText: String?

    public init(
        id: UUID = UUID(),
        items: [CompletionItem],
        selectedIndex: Int? = nil,
        replacementRange: TextRange,
        prefix: String = "",
        emptyText: String? = nil
    ) {
        self.id = id
        self.items = items
        self.selectedIndex = selectedIndex
        self.replacementRange = replacementRange
        self.prefix = prefix
        self.emptyText = emptyText
    }

    public var description: String {
        "CompletionPanelModel(\(items.count) items)"
    }
}
