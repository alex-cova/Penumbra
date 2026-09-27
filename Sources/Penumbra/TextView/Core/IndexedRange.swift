import Foundation
@preconcurrency import AppKit

final class IndexedRange: EditorTextRange {
    let range: NSRange
    override var start: EditorTextPosition {
        IndexedPosition(index: range.location)
    }
    override var end: EditorTextPosition {
        IndexedPosition(index: range.location + range.length)
    }
    override var isEmpty: Bool {
        range.length == 0
    }

    init(_ range: NSRange) {
        self.range = range
    }

    convenience init(location: Int, length: Int) {
        let range = NSRange(location: location, length: length)
        self.init(range)
    }
}
