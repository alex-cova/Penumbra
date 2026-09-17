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
    func setCanvasPaintSpec(_ spec: CanvasPaintSpec)
    func setNeedsDisplay()
    func compactInstanceBuffers()
    /// Line insertion/deletion shifts every following fragment. Metal must rebuild from the
    /// updated frames even when the edited line's glyphs did not change.
    func invalidateForLineStructureChange()
}

struct CanvasPaintSpec {
    var frame: CGRect
    var backgroundColor: UIColor
    var lineSelectionRect: CGRect?
    var lineSelectionColor: UIColor
    var pageGuideFrame: CGRect?
    var pageGuideHairlineWidth: CGFloat
    var pageGuideHairlineColor: UIColor
    var pageGuideShadingColor: UIColor
    var showsPageGuideShading: Bool
    var appearance: NSAppearance?
    var colorSpace: NSColorSpace
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
    /// Output color space selected from the attached window/screen.
    var colorSpace: NSColorSpace = .sRGB
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

extension InvisibleCharacterLayout: Equatable {
    static func == (lhs: InvisibleCharacterLayout, rhs: InvisibleCharacterLayout) -> Bool {
        guard lhs.warnings == rhs.warnings, lhs.symbols.count == rhs.symbols.count else {
            return false
        }
        return zip(lhs.symbols, rhs.symbols).allSatisfy { left, right in
            left.string == right.string
                && left.x == right.x
                && left.isEndOfLine == right.isEndOfLine
                && ((left.color?.isEqual(right.color) == true)
                    || (left.color == nil && right.color == nil))
        }
    }
}

extension LineFragmentDecorations: Equatable {
    static func == (lhs: LineFragmentDecorations, rhs: LineFragmentDecorations) -> Bool {
        lhs.highlighted == rhs.highlighted
            && lhs.markedRange == rhs.markedRange
            && lhs.markedColor.isEqual(rhs.markedColor)
            && lhs.markedRadius == rhs.markedRadius
            && lhs.unfocusedAlpha == rhs.unfocusedAlpha
            && lhs.focusedRanges == rhs.focusedRanges
            && lhs.foldPlaceholder == rhs.foldPlaceholder
            && lhs.foldPlaceholderColor.isEqual(rhs.foldPlaceholderColor)
            && lhs.foldPlaceholderBackgroundColor.isEqual(rhs.foldPlaceholderBackgroundColor)
            && lhs.fragmentRangeUpperBound == rhs.fragmentRangeUpperBound
            && lhs.endsWithLineBreak == rhs.endsWithLineBreak
            && lhs.invisibles == rhs.invisibles
            && lhs.invisibleFont == rhs.invisibleFont
            && lhs.invisibleTextColor.isEqual(rhs.invisibleTextColor)
            && lhs.invisibleWarningColor.isEqual(rhs.invisibleWarningColor)
    }
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

    func setCanvasPaintSpec(_ spec: CanvasPaintSpec) {}

    func setNeedsDisplay() {
        for view in reuseQueue.visibleViews.values {
            view.setNeedsDisplay()
        }
    }

    func compactInstanceBuffers() {}

    func invalidateForLineStructureChange() {}
}
