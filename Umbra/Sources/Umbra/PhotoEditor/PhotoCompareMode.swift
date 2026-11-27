import Foundation

/// Persistent before/after comparison on the canvas. The transient hold-Space / hold-Compare
/// preview (`PhotoEditorSession.isComparing`) is separate and unaffected.
nonisolated enum PhotoCompareMode: String, CaseIterable, Identifiable, Sendable {
    /// Just the edited image.
    case off
    /// A draggable vertical divider: original on the left, edited on the right.
    case split
    /// Original and edited shown at half width each.
    case sideBySide

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .off: "No comparison"
        case .split: "Split"
        case .sideBySide: "Side by side"
        }
    }

    var symbol: String {
        switch self {
        case .off: "rectangle"
        case .split: "rectangle.split.2x1"
        case .sideBySide: "rectangle.split.2x1.fill"
        }
    }

    var next: PhotoCompareMode {
        switch self {
        case .off: .split
        case .split: .sideBySide
        case .sideBySide: .off
        }
    }
}
