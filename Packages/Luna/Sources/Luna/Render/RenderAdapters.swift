import Foundation
import CoreGraphics

// MARK: - Edge Style Parsing

enum EdgeStyleParser {
    static func parse(
        from styleString: String,
        hasArrowStart: Bool,
        hasArrowEnd: Bool,
        startMarker: String = "none",
        endMarker: String = "none"
    ) -> EdgeStyle {
        var lineStyle: LineStyle = .solid
        let sourceArrow: ArrowHead = _arrowHead(marker: startMarker, fallback: hasArrowStart)
        let targetArrow: ArrowHead = _arrowHead(marker: endMarker, fallback: hasArrowEnd)

        switch styleString.lowercased() {
        case "dotted":
            lineStyle = .dotted
        case "dashed":
            lineStyle = .dashed
        case "thick":
            lineStyle = .thick
        default:
            lineStyle = .solid
        }

        return EdgeStyle(lineStyle: lineStyle, sourceArrow: sourceArrow, targetArrow: targetArrow)
    }

    private static func _arrowHead(marker: String, fallback: Bool) -> ArrowHead {
        switch marker.lowercased() {
        case "circle": return .circle
        case "cross": return .cross
        case "arrow": return .arrow
        default: return fallback ? .arrow : .none
        }
    }
}

// MARK: - Render Relationship Type Constants

enum RenderRelType: String {
    case inheritance
    case composition
    case aggregation
    case association
    case dependency
    case realization
}
