import CoreGraphics
import Foundation

/// Trailing-edge fade applied to over-long lines so a truncated line reads as truncated rather
/// than as a solid slab reaching the minimap's edge.
enum MinimapFade {
    static let stepCount = 4
    static let widthPoints: CGFloat = 8

    /// Opacity for a fade step. Step `0` is full opacity; `1...stepCount` step down toward the
    /// edge (0.8, 0.6, 0.4, 0.2 at the default `stepCount`).
    static func alpha(forStep step: Int) -> CGFloat {
        guard step > 0 else {
            return 1
        }
        return max(0, 1 - CGFloat(step) / CGFloat(stepCount + 1))
    }
}

/// Turns one source line's UTF-16 units plus its overlapping syntax-color spans into a
/// `MinimapRow` of drawn segments. Pure: no string fetching, no tree-sitter, no view state, so
/// every rule here (tab expansion, surrogate handling, run merging, column budget, fade split) is
/// unit-testable in isolation.
struct MinimapRowBuilder {
    var maxColumns: Int
    var characterWidth: CGFloat
    var leadingInset: CGFloat
    var tabLength: Int

    private var fadeColumns: Int {
        max(1, Int((MinimapFade.widthPoints / max(characterWidth, 0.5)).rounded()))
    }

    private var fadeStartColumn: Int {
        max(0, maxColumns - fadeColumns)
    }

    private func fadeStep(forColumn column: Int) -> Int {
        guard column >= fadeStartColumn else {
            return 0
        }
        let into = column - fadeStartColumn
        let step = Int((CGFloat(into) / CGFloat(max(fadeColumns, 1))) * CGFloat(MinimapFade.stepCount)) + 1
        return min(step, MinimapFade.stepCount)
    }

    /// - Parameters:
    ///   - units: the line's UTF-16 units, excluding the line delimiter.
    ///   - colorSpans: line-local column ranges already resolved to `MinimapPalette` indices, in
    ///     the order they should be applied — later entries win on overlap, matching how the real
    ///     syntax highlighter layers captures.
    func makeRow(utf16 units: ArraySlice<unichar>, colorSpans: [(range: Range<Int>, colorIndex: Int)]) -> MinimapRow {
        guard maxColumns > 0, !units.isEmpty else {
            return .empty
        }

        // Per-column color, base by default, overwritten by each span in order.
        var colorAt = [Int](repeating: 0, count: maxColumns)
        for span in colorSpans where span.colorIndex != 0 {
            let lower = max(0, span.range.lowerBound)
            let upper = min(maxColumns, span.range.upperBound)
            guard lower < upper else {
                continue
            }
            for column in lower ..< upper {
                colorAt[column] = span.colorIndex
            }
        }

        var segments: [MinimapSegment] = []
        var column = 0
        var runStart = -1
        var runColor = 0
        var runFadeStep = 0

        func flushRun() {
            guard runStart >= 0 else {
                return
            }
            segments.append(MinimapSegment(
                x: leadingInset + CGFloat(runStart) * characterWidth,
                width: CGFloat(column - runStart) * characterWidth,
                colorIndex: runColor,
                fadeStep: runFadeStep
            ))
            runStart = -1
        }

        for unit in units {
            if column >= maxColumns {
                break
            }
            switch unit {
            case 0x09: // tab
                flushRun()
                column += tabLength - (column % max(tabLength, 1))
            case 0x20, 0x0A, 0x0D: // space, LF, CR
                flushRun()
                column += 1
            case 0xDC00 ... 0xDFFF: // low surrogate — already counted with its high surrogate
                continue
            default:
                let color = colorAt[column]
                let step = fadeStep(forColumn: column)
                if runStart >= 0, runColor != color || runFadeStep != step {
                    flushRun()
                }
                if runStart < 0 {
                    runStart = column
                    runColor = color
                    runFadeStep = step
                }
                column += 1
            }
        }
        flushRun()
        return MinimapRow(segments: segments)
    }

    /// A row with no syntax coloring — every non-whitespace column at the base color.
    func makeFlatRow(utf16 units: ArraySlice<unichar>) -> MinimapRow {
        makeRow(utf16: units, colorSpans: [])
    }
}
