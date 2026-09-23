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
    var separatorRows: Set<Int> = [] {
        didSet { if separatorRows != oldValue { needsDisplay = true } }
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
        let lineYPositions: [CGFloat] = separatorRows.sorted().compactMap { row in
            guard row > 0, row < lineCount else {
                return nil
            }
            let line = lineManager.line(atRow: row)
            guard line.data.lineHeight > 0 else {
                return nil
            }
            return line.yPosition
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
