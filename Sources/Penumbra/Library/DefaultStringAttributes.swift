import Foundation
@preconcurrency import AppKit

struct DefaultStringAttributes {
    let textColor: UIColor
    let font: UIFont
    let kern: CGFloat
    let tabWidth: CGFloat

    func apply(to attributedString: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: attributedString.length)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: font,
            .kern: kern as NSNumber,
            .paragraphStyle: Self.paragraphStyle(tabWidth: tabWidth)
        ]
        attributedString.beginEditing()
        attributedString.setAttributes(attributes, range: range)
        attributedString.endEditing()
    }
}

private extension DefaultStringAttributes {
    /// Tab-stop lists are identical for a given `tabWidth`. Building twenty `NSTextTab`s on every
    /// line typeset dominated default-attribute apply time on large viewports.
    private static let paragraphStyleLock = NSLock()
    nonisolated(unsafe) private static var paragraphStyles: [Int: NSParagraphStyle] = [:]

    static func paragraphStyle(tabWidth: CGFloat) -> NSParagraphStyle {
        let key = Int((tabWidth * 4).rounded())
        paragraphStyleLock.lock()
        if let cached = paragraphStyles[key] {
            paragraphStyleLock.unlock()
            return cached
        }
        paragraphStyleLock.unlock()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = (0 ..< 20).map { index in
            NSTextTab(textAlignment: .left, location: CGFloat(index) * tabWidth)
        }
        paragraphStyle.defaultTabInterval = tabWidth
        let copy = paragraphStyle.copy() as? NSParagraphStyle ?? paragraphStyle
        paragraphStyleLock.lock()
        paragraphStyles[key] = copy
        paragraphStyleLock.unlock()
        return copy
    }
}
