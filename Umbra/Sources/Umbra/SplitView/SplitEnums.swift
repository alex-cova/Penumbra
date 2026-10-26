//  Vendored from SplitView (MIT) — Copyright (c) 2023 Steven G. Harris.
//  See LICENSE in this directory. Ported for Hextech, then Umbra: see README.md.

import Foundation

/// The orientation of the `primary` and `secondary` views (e.g., Vertical = VStack, Horizontal = HStack)
enum SplitLayout: String, CaseIterable, Sendable {
    case horizontal
    case vertical
}

/// The two sides of a SplitView.
///
/// Use `isPrimary` and `isSecondary` rather than accessing the cases directly.
///
/// For `SplitLayout.horizontal`, `primary` is left, `secondary` is right.
/// For `SplitLayout.vertical`, `primary` is top, `secondary` is bottom.
enum SplitSide: String, Sendable {
    case primary
    case secondary
    case left
    case right
    case top
    case bottom

    var isPrimary: Bool { self == .primary || self == .left || self == .top }
    var isSecondary: Bool { self == .secondary || self == .right || self == .bottom }
}

/// A SplitSide is generally optional. If so, then if nil, it is neither primary nor secondary.
extension Optional where Wrapped == SplitSide {
    var isPrimary: Bool { self?.isPrimary ?? false }
    var isSecondary: Bool { self?.isSecondary ?? false }
}
