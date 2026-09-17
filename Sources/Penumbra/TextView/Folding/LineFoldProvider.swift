import Foundation

/// A fold start or end signal produced by a ``LineFoldProvider`` for a single line.
///
/// `depth` is the nesting depth *after* the event is applied. Providers may return more than one
/// event for a single line (e.g. a line that both closes one fold and opens another, such as
/// `} else {`).
enum LineFoldEvent {
    case startFold(depth: Int)
    case endFold(depth: Int)

    var depth: Int {
        switch self {
        case .startFold(let depth), .endFold(let depth):
            return depth
        }
    }
}

/// Finds foldable regions in a document.
///
/// The editor calls ``foldEvents(atLine:previousDepth:in:stringView:)`` once per line, in order,
/// while recomputing the document's fold structure. Implementations should be fast, since this is
/// called once per line of a recompute window.
protocol LineFoldProvider: AnyObject {
    func foldEvents(atLine lineIndex: Int, previousDepth: Int, in lineManager: LineManager, stringView: StringView) -> [LineFoldEvent]
    /// Called after an edit so cached providers can update a slice of the document instead of
    /// throwing away the whole fold map. Default is a no-op.
    func invalidateForEdit(changedRows: ClosedRange<Int>?, lineCount: Int, previousLineCount: Int, spliceRow: Int)
}

extension LineFoldProvider {
    func invalidateForEdit(changedRows: ClosedRange<Int>?, lineCount: Int, previousLineCount: Int, spliceRow: Int) {}
}
