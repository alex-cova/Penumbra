@preconcurrency import AppKit
import Foundation

/// Draws a thin horizontal rule above each method/function declaration.
///
/// The rule is the same hairline as the right margin (`PageGuideView`): one device pixel,
/// `pageGuideHairlineColor` at `pageGuideHairlineOpacity`. Like `FoldRibbonView`, this view spans
/// the document and scrolls with it, so Core Graphics drawing is scoped to `dirtyRect`. When Metal
/// is the paint backend the opaque canvas covers this view; `LayoutManager` replays
/// ``separatorLineFrames(clip:)`` into the canvas underlay, the same path as the page-guide hairline.
final class MethodSeparatorView: UIView {
    weak var lineManager: LineManager?
    var textContainerInsetTop: CGFloat = 0 {
        didSet { if textContainerInsetTop != oldValue { needsDisplay = true } }
    }
    /// 0-based document rows that get a separator drawn along their top edge.
    /// Sorted and unique (as ``MethodSeparatorController`` publishes them).
    var separatorRows: [Int] = [] {
        didSet {
            if separatorRows != oldValue {
                needsDisplay = true
            }
        }
    }
    var separatorColor: UIColor = .separatorColor {
        didSet { needsDisplay = true }
    }
    var separatorWidth: CGFloat = 1 {
        didSet { if separatorWidth != oldValue { needsDisplay = true } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Content-space hairlines for `separatorRows`, clipped to `clip`. Empty when the view has no
    /// width yet. Row order is sorted so Metal's underlay equality check stays stable.
    func separatorLineFrames(clip: CGRect) -> [CGRect] {
        guard let lineManager, !separatorRows.isEmpty, separatorWidth > 0, bounds.width > 0 else {
            return []
        }
        let lineCount = lineManager.lineCount
        // Only rows whose top edge can land inside `clip`: this runs on every layout pass, and a
        // large file has thousands of declarations.
        let slack = separatorWidth + 1
        let firstRow = lineManager.row(containingYOffset: clip.minY - textContainerInsetTop - slack) ?? 0
        let lastRow = (lineManager.row(containingYOffset: clip.maxY - textContainerInsetTop + slack) ?? lineCount) + 1
        let rows = separatorRows
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid] < firstRow {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var candidates: [Int] = []
        var index = low
        while index < rows.count, rows[index] <= lastRow {
            candidates.append(rows[index])
            index += 1
        }
        let lineYPositions: [CGFloat] = candidates.compactMap { row in
            guard row > 0, row < lineCount else {
                return nil
            }
            // Handle-free reads: this runs on every layout pass.
            guard lineManager.lineInfo(atRow: row).lineHeight > 0 else {
                return nil
            }
            return lineManager.yPosition(ofRow: row)
        }
        return MethodSeparatorGeometry.frames(
            lineYPositions: lineYPositions,
            insetTop: textContainerInsetTop,
            width: bounds.width,
            thickness: separatorWidth,
            clip: clip
        )
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let frames = separatorLineFrames(clip: dirtyRect)
        guard !frames.isEmpty else {
            return
        }
        context.setFillColor(separatorColor.cgColor)
        for frame in frames {
            context.fill(frame)
        }
    }
}

/// Horizontal hairline rects shared by Core Graphics and the Metal underlay.
enum MethodSeparatorGeometry {
    static func frames(
        lineYPositions: [CGFloat],
        insetTop: CGFloat,
        width: CGFloat,
        thickness: CGFloat,
        clip: CGRect
    ) -> [CGRect] {
        guard width > 0, thickness > 0, !lineYPositions.isEmpty else {
            return []
        }
        var frames: [CGRect] = []
        frames.reserveCapacity(lineYPositions.count)
        for lineY in lineYPositions {
            let y = (insetTop + lineY - thickness / 2).rounded()
            let rect = CGRect(x: 0, y: y, width: width, height: thickness)
            guard rect.maxY >= clip.minY, rect.minY <= clip.maxY else {
                continue
            }
            frames.append(rect)
        }
        return frames
    }
}
