import Foundation

/// A foldable region discovered by a language folding builder.
public struct FoldingDescriptor: Sendable, Hashable {
    public let range: TextRange
    public let placeholder: String
    public let collapsedByDefault: Bool
    public let groupID: String?

    public init(
        range: TextRange,
        placeholder: String,
        collapsedByDefault: Bool = false,
        groupID: String? = nil
    ) {
        self.range = range
        self.placeholder = placeholder
        self.collapsedByDefault = collapsedByDefault
        self.groupID = groupID
    }
}
