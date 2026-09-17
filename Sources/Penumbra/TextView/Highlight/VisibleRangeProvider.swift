@preconcurrency import AppKit
import Foundation

/// Tracks which character indices are visible in the editor and notifies listeners when the set changes.
@MainActor
final class VisibleRangeProvider {
    @MainActor
    protocol Delegate: AnyObject {
        func visibleRangeProvider(_ provider: VisibleRangeProvider, didUpdate indices: IndexSet)
    }

    weak var delegate: Delegate?
    private weak var textView: TextView?

    private(set) var visibleIndices: IndexSet = []

    init(textView: TextView) {
        self.textView = textView
        refreshVisibleSet()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollDidChange),
            name: NSView.boundsDidChangeNotification,
            object: textView
        )
        textView.postsBoundsChangedNotifications = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refreshVisibleSet() {
        guard let textView else {
            return
        }
        let length = textView.text.utf16.count
        guard length > 0 else {
            visibleIndices = []
            return
        }
        let viewportY = textView.contentOffset.y
        let viewportHeight = textView.bounds.height
        let startLine = max(0, Int(viewportY / max(textView.lineHeightMultiplier * 16, 1)))
        let endLine = startLine + Int(viewportHeight / max(textView.lineHeightMultiplier * 16, 1)) + 2
        var startOffset = 0
        var endOffset = length
        if let startLocation = textView.location(at: TextLocation(lineNumber: startLine, column: 0)) {
            startOffset = startLocation
        }
        if let endLocation = textView.location(at: TextLocation(lineNumber: endLine, column: 0)) {
            endOffset = min(length, endLocation)
        }
        let newSet = IndexSet(integersIn: startOffset..<max(startOffset, endOffset))
        guard newSet != visibleIndices else {
            return
        }
        visibleIndices = newSet
        delegate?.visibleRangeProvider(self, didUpdate: newSet)
    }

    @objc private func scrollDidChange() {
        refreshVisibleSet()
    }
}
