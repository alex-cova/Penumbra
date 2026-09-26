import Foundation

/// A fold region in the editor model.
///
/// `lineRange.lowerBound` is the fold's header line — it stays visible when collapsed.
/// Lines in `(lineRange.lowerBound + 1)...lineRange.upperBound` are hidden when collapsed.
struct FoldRegion: Equatable, Identifiable {
    let id: UUID
    let depth: Int
    var lineRange: ClosedRange<Int>
    var placeholder: String
    var groupID: String?
    var isExpanded: Bool

    var isCollapsed: Bool {
        !isExpanded
    }

    /// The line range hidden when collapsed, i.e. `lineRange` minus the header line.
    var hiddenLineRange: ClosedRange<Int>? {
        guard lineRange.upperBound > lineRange.lowerBound else {
            return nil
        }
        return (lineRange.lowerBound + 1) ... lineRange.upperBound
    }

    init(
        id: UUID = UUID(),
        depth: Int,
        lineRange: ClosedRange<Int>,
        placeholder: String,
        groupID: String? = nil,
        isExpanded: Bool = true
    ) {
        self.id = id
        self.depth = depth
        self.lineRange = lineRange
        self.placeholder = placeholder
        self.groupID = groupID
        self.isExpanded = isExpanded
    }
}
