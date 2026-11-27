import CoreGraphics
import Foundation

/// One straight segment of a canvas grid overlay, in view points.
nonisolated struct PhotoGridLine: Equatable, Sendable {
    var start: CGPoint
    var end: CGPoint
}

/// Composition overlays offered by the canvas grid menu.
nonisolated enum PhotoGridStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case thirds
    case goldenRatio
    case square
    case diagonals
    case centerCross

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .thirds: "Rule of Thirds"
        case .goldenRatio: "Golden Ratio"
        case .square: "Square Grid"
        case .diagonals: "Diagonals"
        case .centerCross: "Center Cross"
        }
    }

    var symbol: String {
        switch self {
        case .off: "grid"
        case .thirds: "grid"
        case .goldenRatio: "rectangle.split.3x3"
        case .square: "squareshape.split.3x3"
        case .diagonals: "line.diagonal"
        case .centerCross: "plus"
        }
    }
}

/// Pure geometry for the canvas grid. All results are in view points; the caller strokes them into a
/// single `Path`.
nonisolated enum PhotoGridRenderer {
    /// A grid whose lines would fall closer than this is doubled up until it wouldn't — keeps a
    /// low-zoom square grid from turning into a grey wash.
    static let minVisibleSpacing: CGFloat = 4

    /// The per-pixel grid appears once one image pixel spans at least this many points.
    static let pixelGridMinScale: CGFloat = 4

    static func lines(style: PhotoGridStyle, in rect: CGRect, squareSpacing: CGFloat) -> [PhotoGridLine] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        switch style {
        case .off:
            return []
        case .thirds:
            return fractionLines(in: rect, fractions: [1.0 / 3.0, 2.0 / 3.0])
        case .goldenRatio:
            return fractionLines(in: rect, fractions: [0.381966, 0.618034])
        case .centerCross:
            return fractionLines(in: rect, fractions: [0.5])
        case .diagonals:
            return [
                PhotoGridLine(start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY)),
                PhotoGridLine(start: CGPoint(x: rect.maxX, y: rect.minY), end: CGPoint(x: rect.minX, y: rect.maxY)),
            ]
        case .square:
            return squareLines(in: rect, spacing: squareSpacing)
        }
    }

    private static func fractionLines(in rect: CGRect, fractions: [CGFloat]) -> [PhotoGridLine] {
        var lines: [PhotoGridLine] = []
        for fraction in fractions {
            let x = rect.minX + rect.width * fraction
            let y = rect.minY + rect.height * fraction
            lines.append(PhotoGridLine(start: CGPoint(x: x, y: rect.minY), end: CGPoint(x: x, y: rect.maxY)))
            lines.append(PhotoGridLine(start: CGPoint(x: rect.minX, y: y), end: CGPoint(x: rect.maxX, y: y)))
        }
        return lines
    }

    private static func squareLines(in rect: CGRect, spacing rawSpacing: CGFloat) -> [PhotoGridLine] {
        var spacing = max(rawSpacing, 1)
        while spacing < minVisibleSpacing { spacing *= 2 }
        var lines: [PhotoGridLine] = []
        var x = rect.minX + spacing
        while x < rect.maxX {
            lines.append(PhotoGridLine(start: CGPoint(x: x, y: rect.minY), end: CGPoint(x: x, y: rect.maxY)))
            x += spacing
        }
        var y = rect.minY + spacing
        while y < rect.maxY {
            lines.append(PhotoGridLine(start: CGPoint(x: rect.minX, y: y), end: CGPoint(x: rect.maxX, y: y)))
            y += spacing
        }
        return lines
    }

    /// True once the image is magnified enough (`>= pixelGridMinScale` points per source pixel) for a
    /// per-pixel grid to be legible.
    static func pixelGridIsVisible(imageRect: CGRect, imagePixelSize: CGSize) -> Bool {
        guard imagePixelSize.width >= 1, imageRect.width > 0 else { return false }
        return imageRect.width / imagePixelSize.width >= pixelGridMinScale
    }

    /// A line on every source-pixel boundary, clipped to `viewBounds` so a large image at high zoom
    /// emits only the handful of segments actually on screen. Empty below `pixelGridMinScale`.
    static func pixelGridLines(
        imageRect: CGRect,
        imagePixelSize: CGSize,
        viewBounds: CGRect
    ) -> [PhotoGridLine] {
        guard pixelGridIsVisible(imageRect: imageRect, imagePixelSize: imagePixelSize),
              imagePixelSize.height >= 1 else { return [] }
        let visible = imageRect.intersection(viewBounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return [] }

        let scaleX = imageRect.width / imagePixelSize.width
        let scaleY = imageRect.height / imagePixelSize.height
        var lines: [PhotoGridLine] = []

        let firstCol = max(0, Int(floor((visible.minX - imageRect.minX) / scaleX)))
        let lastCol = min(Int(imagePixelSize.width), Int(ceil((visible.maxX - imageRect.minX) / scaleX)))
        if firstCol <= lastCol {
            for col in firstCol...lastCol {
                let x = imageRect.minX + CGFloat(col) * scaleX
                lines.append(PhotoGridLine(
                    start: CGPoint(x: x, y: visible.minY),
                    end: CGPoint(x: x, y: visible.maxY)
                ))
            }
        }

        let firstRow = max(0, Int(floor((visible.minY - imageRect.minY) / scaleY)))
        let lastRow = min(Int(imagePixelSize.height), Int(ceil((visible.maxY - imageRect.minY) / scaleY)))
        if firstRow <= lastRow {
            for row in firstRow...lastRow {
                let y = imageRect.minY + CGFloat(row) * scaleY
                lines.append(PhotoGridLine(
                    start: CGPoint(x: visible.minX, y: y),
                    end: CGPoint(x: visible.maxX, y: y)
                ))
            }
        }
        return lines
    }
}
