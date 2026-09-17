import Foundation

/// A single foldable region of the document, expressed in terms of line indices (rows) rather
/// than character offsets.
///
/// `lineRange.lowerBound` is the fold's "header" line — it always stays visible, even while the
/// fold is collapsed, so the surrounding structure (e.g. `func foo() {`) remains legible. The
/// lines in `(lineRange.lowerBound + 1)...lineRange.upperBound` are the ones hidden when the fold
/// is collapsed.
struct FoldRange: Equatable {
    let id: Int
    let depth: Int
    var lineRange: ClosedRange<Int>
    var isCollapsed: Bool

    /// The line range that is actually hidden when collapsed, i.e. `lineRange` minus the header
    /// line. `nil` when the fold spans only its header line (nothing to hide).
    var hiddenLineRange: ClosedRange<Int>? {
        guard lineRange.upperBound > lineRange.lowerBound else {
            return nil
        }
        return (lineRange.lowerBound + 1) ... lineRange.upperBound
    }
}
