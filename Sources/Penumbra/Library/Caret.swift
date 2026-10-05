import Foundation
@preconcurrency import AppKit

enum Caret {
    static let width: CGFloat = 2

    static func defaultHeight(for font: NSFont?) -> CGFloat {
        font?.lineHeight ?? 15
    }
}

/// How the insertion caret is drawn.
///
/// ``TextView/caretRect(at:)`` stays the thin bar in every case. Selection geometry and
/// popups anchor to that bar; only the caret's own frame follows ``TextView/caretShape``.
public enum CaretShape: String, Codable, Sendable, CaseIterable, Hashable {
    /// A vertical bar the full height of the line.
    case bar
    /// A block covering the character after the caret. The character is redrawn in the
    /// editor background so it stays readable.
    case block
    /// A horizontal stroke on the baseline, one character wide.
    case underline
}
