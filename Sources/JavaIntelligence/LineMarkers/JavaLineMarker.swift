import EditorIntelligence
import Foundation

/// What a Java gutter marker says about the declaration or call on its line: the generic
/// ``LineMarkerKind`` (same cases and raw values, so saved preferences keep working).
public typealias JavaLineMarkerKind = LineMarkerKind

/// One gutter marker for a Java file.
public struct JavaLineMarker: Hashable, Sendable {
    public let kind: JavaLineMarkerKind
    /// 1-based line, counted as the editor counts them (`\r\n` is one break).
    public let line: Int
    /// UTF-16 offset of the declaration or call name. Go to Super Method or Go to Implementation
    /// resolved here lands where the marker points.
    public let anchorUTF16Offset: Int
    public let tooltip: String
    /// For ``JavaLineMarkerKind/siblingInherited``: the interface methods implemented.
    public let targets: [JavaSymbolID]

    public init(kind: JavaLineMarkerKind, line: Int, anchorUTF16Offset: Int, tooltip: String, targets: [JavaSymbolID] = []) {
        self.kind = kind
        self.line = line
        self.anchorUTF16Offset = anchorUTF16Offset
        self.tooltip = tooltip
        self.targets = targets
    }
}
