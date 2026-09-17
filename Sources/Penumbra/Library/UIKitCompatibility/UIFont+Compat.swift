@preconcurrency import AppKit
import Foundation

extension NSFont {
    var lineHeight: CGFloat { totalLineHeight }
    var totalLineHeight: CGFloat { ascender + abs(descender) + leading }
}
