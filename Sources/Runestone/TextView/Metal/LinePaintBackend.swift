import CoreText
import Foundation
@preconcurrency import AppKit

@MainActor
protocol LinePaintBackend: AnyObject {
    var trackedFragmentIDs: Set<LineFragmentID> { get }
    /// LayoutManager supplies the payload; the backend does not read `LineFragmentController`.
    func upsertFragment(_ spec: LineFragmentPaintSpec)
    func removeFragments(ids: Set<LineFragmentID>)
    func invalidateGlyphs(forLineIDs ids: Set<DocumentLineNodeID>)
    func setViewport(_ viewport: CGRect, canvasFrame: CGRect, scale: CGFloat)
    func setNeedsDisplay()
    func compactInstanceBuffers()
}

struct LineFragmentPaintSpec {
    var id: LineFragmentID
    var lineID: DocumentLineNodeID
    var frame: CGRect
    var line: CTLine
    var descent: CGFloat
    var baseSize: CGSize
    var scaledSize: CGSize
    var decorations: LineFragmentDecorations
    /// Font used when a `CTRun` carries no `.font` attribute. `LayoutManager` supplies `theme.font`.
    var fallbackFont: CTFont
    /// Color used when a `CTRun` carries no `.foregroundColor` attribute (`theme.textColor`).
    var fallbackColor: UIColor
    /// Appearance to resolve dynamic colors against; the Metal backend needs it off the render pass.
    var appearance: NSAppearance?
    /// Monotonic identity for `line`, immune to `CTLine` pointer reuse (`LineFragment.revision`).
    /// Metal keys its glyph-extraction cache on this instead of `ObjectIdentifier(line)`.
    var lineRevision: UInt64
    /// `true` when `line` was typeset before syntax highlighting completed, i.e. its colors are
    /// still `fallbackColor` rather than the eventual syntax colors. Metal holds the previously
    /// extracted (colored) glyphs instead of baking this provisional state to the screen.
    var isSyntaxHighlightPending: Bool = false
}

struct LineFragmentDecorations {
    var highlighted: [HighlightedRangeFragment]
    var markedRange: NSRange?
    var markedColor: UIColor
    var markedRadius: CGFloat
    var unfocusedAlpha: CGFloat
    var focusedRanges: [NSRange]
    var foldPlaceholder: String?
    var foldPlaceholderColor: UIColor = .secondaryLabelColor
    var foldPlaceholderBackgroundColor: UIColor = .quaternaryLabelColor
    /// Fragment-local end of the fragment's character range (`LineFragment.range.upperBound`); with
    /// `endsWithLineBreak` it decides whether a `.standard` highlight extends to the canvas edge.
    var fragmentRangeUpperBound: Int = 0
    var endsWithLineBreak: Bool = false
    /// Resolved invisible-character markers for this fragment (empty when the feature is off). The
    /// Metal backend does not read `InvisibleCharacterConfiguration`; `LayoutManager` resolves it.
    var invisibles: InvisibleCharacterLayout = .empty
    var invisibleFont: UIFont = .systemFont(ofSize: 12)
    var invisibleTextColor: UIColor = .label
    var invisibleWarningColor: UIColor = .systemRed
}

/// CG path: today's `ViewReuseQueue` + `LineFragmentView` drawing.
@MainActor
final class CGLinePaintBackend: LinePaintBackend {
    private let reuseQueue = ViewReuseQueue<LineFragmentID, LineFragmentView>()
    private weak var linesContainerView: UIView?
    private var fragmentLineIDs: [LineFragmentID: DocumentLineNodeID] = [:]

    var trackedFragmentIDs: Set<LineFragmentID> {
        Set(reuseQueue.visibleViews.keys)
    }

    init(linesContainerView: UIView) {
        self.linesContainerView = linesContainerView
    }

    func lineFragmentView(for id: LineFragmentID) -> LineFragmentView? {
        reuseQueue.visibleViews[id]
    }

    func upsertFragment(_ spec: LineFragmentPaintSpec) {
        fragmentLineIDs[spec.id] = spec.lineID
        let view = reuseQueue.dequeueView(forKey: spec.id)
        if view.superview == nil {
            linesContainerView?.addSubview(view)
        }
        view.frame = spec.frame
    }

    func removeFragments(ids: Set<LineFragmentID>) {
        for id in ids {
            fragmentLineIDs.removeValue(forKey: id)
        }
        reuseQueue.enqueueViews(withKeys: ids)
    }

    func invalidateGlyphs(forLineIDs ids: Set<DocumentLineNodeID>) {
        for (fragmentID, lineID) in fragmentLineIDs where ids.contains(lineID) {
            reuseQueue.visibleViews[fragmentID]?.setNeedsDisplay()
        }
    }

    func setViewport(_ viewport: CGRect, canvasFrame: CGRect, scale: CGFloat) {}

    func setNeedsDisplay() {
        for view in reuseQueue.visibleViews.values {
            view.setNeedsDisplay()
        }
    }

    func compactInstanceBuffers() {}
}
