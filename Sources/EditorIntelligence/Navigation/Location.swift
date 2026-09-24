import Foundation

/// A concrete location in a document, returned by navigation providers.
public struct Location: Sendable, Hashable, Identifiable, CustomStringConvertible {
    public let id: UUID
    public let documentID: DocumentID
    public let url: URL?
    public let range: TextRange
    public let displayName: String
    /// Extra facts a results list can show for a usage; nil for plain navigation targets.
    public let usage: UsageInfo?

    /// How a usage reads in a list: what kind of use it is, how sure the resolver is, and the
    /// source line with the matched identifier's UTF-16 range inside it.
    public struct UsageInfo: Sendable, Hashable {
        public let kindLabel: String
        public let isAmbiguous: Bool
        public let lineText: String
        public let matchRange: NSRange
        /// Zero-based line of the usage.
        public let line: Int

        public init(kindLabel: String, isAmbiguous: Bool, lineText: String, matchRange: NSRange, line: Int) {
            self.kindLabel = kindLabel
            self.isAmbiguous = isAmbiguous
            self.lineText = lineText
            self.matchRange = matchRange
            self.line = line
        }
    }

    public init(
        id: UUID = UUID(),
        documentID: DocumentID,
        url: URL? = nil,
        range: TextRange,
        displayName: String,
        usage: UsageInfo? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.url = url
        self.range = range
        self.displayName = displayName
        self.usage = usage
    }

    public var description: String {
        "\(displayName) @ \(documentID) \(range)"
    }
}
