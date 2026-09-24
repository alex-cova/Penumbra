import Foundation

/// A clickable icon drawn in the editor gutter beside a line.
public struct GutterDecoration: Equatable, Sendable {
    /// 1-based document line.
    public let line: Int
    public let symbolName: String
    public let accessibilityLabel: String

    public init(line: Int, symbolName: String, accessibilityLabel: String) {
        self.line = line
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel
    }
}
