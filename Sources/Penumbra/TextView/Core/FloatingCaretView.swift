import Foundation
@preconcurrency import AppKit

final class FloatingCaretView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        wantsLayer = true
        layer?.cornerRadius = floor(bounds.width / 2)
    }
}
