import Foundation
@preconcurrency import AppKit

final class FloatingCaretView: EditorView {
    override func layoutSubviews() {
        super.layoutSubviews()
        wantsLayer = true
        layer?.cornerRadius = floor(bounds.width / 2)
    }
}
