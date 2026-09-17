import Foundation
@preconcurrency import AppKit

enum Caret {
    static let width: CGFloat = 2

    static func defaultHeight(for font: UIFont?) -> CGFloat {
        font?.lineHeight ?? 15
    }
}
