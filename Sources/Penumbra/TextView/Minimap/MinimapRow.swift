import CoreGraphics
import Foundation

/// One drawn rectangle in a minimap row: a run of non-whitespace characters at a fixed color and
/// fade step. `x`/`width` are already in minimap view coordinates (leading inset applied, column
/// budget clamped).
struct MinimapSegment: Equatable {
    var x: CGFloat
    var width: CGFloat
    /// Index into `MinimapPalette`.
    var colorIndex: Int
    /// `0` = full opacity; higher values step down the alpha over the trailing fade strip.
    var fadeStep: Int
}

/// The cached, geometry-independent description of one source line's minimap bar. Vertical
/// placement is applied at draw time from the current `MinimapGeometry`, so a row survives
/// scrolling untouched.
struct MinimapRow: Equatable {
    var segments: [MinimapSegment]

    static let empty = MinimapRow(segments: [])
}

/// Interns `UIColor`s by tree-sitter capture name so the draw loop can group fills by a small
/// integer instead of comparing colors. Index `0` is always the theme's base text color.
final class MinimapPalette {
    private(set) var colors: [UIColor]
    private var indexByName: [String: Int] = [:]

    init(baseColor: UIColor) {
        colors = [baseColor]
    }

    var baseColorIndex: Int { 0 }

    /// Resolves (and caches) the palette index for a capture name against `theme`.
    func index(forCaptureName name: String, theme: Theme) -> Int {
        if let existing = indexByName[name] {
            return existing
        }
        let color = theme.textColor(for: name) ?? colors[0]
        let index = colors.count
        colors.append(color)
        indexByName[name] = index
        return index
    }
}
