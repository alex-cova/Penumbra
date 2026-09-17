import Foundation

/// Edge used when splitting a pane within the layout tree.
public enum EditorSplitEdge: String, Equatable, Codable, Sendable {
    case leading
    case trailing
    case top
    case bottom
}
