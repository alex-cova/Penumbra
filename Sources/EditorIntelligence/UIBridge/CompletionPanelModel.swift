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
    /// A contributor is still producing a later batch.
    public let isComputing: Bool
    /// Hint under the list: a second Ctrl+Space, or smart completion.
    public let advertisement: String?
    /// Show "⏎ Insert · ⇥ Replace" in the footer while there are rows. Off for lists where the
    /// two keys do not differ (the read-only command list).
    public let showsKeyHint: Bool

    public init(
        id: UUID = UUID(),
        items: [CompletionItem],
        selectedIndex: Int? = nil,
        replacementRange: TextRange,
        prefix: String = "",
        emptyText: String? = nil,
        isComputing: Bool = false,
        advertisement: String? = nil,
        showsKeyHint: Bool = true
    ) {
        self.id = id
        self.items = items
        self.selectedIndex = selectedIndex
        self.replacementRange = replacementRange
        self.prefix = prefix
        self.emptyText = emptyText
        self.isComputing = isComputing
        self.advertisement = advertisement
        self.showsKeyHint = showsKeyHint
    }

    public var showsFooter: Bool {
        isComputing || (advertisement?.isEmpty == false) || showsKeyHintRow
    }

    /// The footer carries the key hint: there are rows to accept and the host wants it shown.
    public var showsKeyHintRow: Bool {
        showsKeyHint && !items.isEmpty
    }

    public var description: String {
        "CompletionPanelModel(\(items.count) items)"
    }
}
