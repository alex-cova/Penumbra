import Foundation

public struct BreadcrumbSegment: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let range: TextRange

    public init(id: UUID = UUID(), title: String, range: TextRange) {
        self.id = id
        self.title = title
        self.range = range
    }
}

public struct BreadcrumbBarModel: Sendable {
    /// Enclosing scopes worth showing. A longer trail is not readable, and it is what used to
    /// lay a control out for every word in the file.
    public static let maximumSegments = 12

    public let segments: [BreadcrumbSegment]

    public init(segments: [BreadcrumbSegment]) {
        self.segments = segments
    }

    /// The innermost segments, when a provider handed back more than ``maximumSegments``.
    public static func capped(_ segments: [BreadcrumbSegment]) -> [BreadcrumbSegment] {
        guard segments.count > maximumSegments else { return segments }
        return Array(segments.suffix(maximumSegments))
    }
}
