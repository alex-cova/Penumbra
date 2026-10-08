import Foundation

/// One clickable label of a code vision lens: `3 usages`, `2 implementations`.
public struct CodeVisionEntry: Sendable, Hashable {
    /// Tells the host which action a click means (`usages`, `implementations`).
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// A line of labels shown above a declaration, without being part of the text.
///
/// Lenses are display-only. The editor keeps each on its line as the text is edited until the
/// provider sends fresh ones.
public struct CodeVisionLens: Sendable, Hashable {
    /// The UTF-16 offset of the declaration's name; the lens sits above the line holding it.
    public let utf16Offset: Int
    /// The labels. Empty while the numbers are still being worked out: the room above the line is
    /// already reserved, so the text does not move when they arrive.
    public let entries: [CodeVisionEntry]

    public init(utf16Offset: Int, entries: [CodeVisionEntry] = []) {
        self.utf16Offset = utf16Offset
        self.entries = entries
    }
}

/// Supplies the lenses for a document in two steps, so the room above declarations can be kept
/// from the start and the numbers can follow for what is on screen.
public protocol CodeVisionProviding: Sendable {
    /// The UTF-16 offsets of the names of every declaration that gets a lens. Cheap: a pass over
    /// the syntax tree, no searching.
    func codeVisionAnchors(for document: Document) async -> [Int]

    /// The lenses, with their labels, for the anchors in `anchors` (a subset of what
    /// ``codeVisionAnchors(for:)`` returned). A provider should bound its work, since this runs
    /// whenever the visible text changes.
    func codeVision(for document: Document, anchors: [Int]) async -> [CodeVisionLens]
}
