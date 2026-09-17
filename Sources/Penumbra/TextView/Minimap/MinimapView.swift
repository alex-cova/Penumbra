@preconcurrency import AppKit
import Foundation

/// A miniature, syntax-colored overview of the document rendered along the trailing edge of the
/// text view, like the minimap in Xcode and VS Code. Each source line becomes one fixed-height
/// row of small colored blocks — one block per run of non-whitespace characters, filled with that
/// token's syntax color — so the minimap reads like the code it mirrors, indentation included. A
/// draggable box frames the portion visible in the editor; dragging it, or clicking elsewhere,
/// scrolls the editor.
///
/// It never typesets or renders glyphs. Colors come straight from tree-sitter captures
/// (`MinimapContentSource.minimapCaptures(inByteRange:)`) mapped through the theme — one query and
/// one string fetch per cold band — and finished rows are cached per line
/// (``MinimapRowCache``), so scrolling back over visited ground is nearly free and an unchanged
/// frame is skipped entirely.
///
/// All scroll geometry goes through ``MinimapGeometry``, which places the viewport indicator
/// first (always inside the minimap's bounds) and derives the drawn content's offset from it, so
/// the box can neither leave the view nor drift away from the rows it frames — regardless of
/// `textContainerInset`, typewriter overscroll, line wrapping, or folding.
final class MinimapView: UIView {
    /// Source of line/string/syntax data this minimap reflects. Not owned by the minimap.
    weak var lineDataSource: TextInputView?
    /// The scroll view whose `contentOffset`/`contentSize` this minimap reflects and controls.
    weak var scrollView: TextView?
    /// Called before the minimap changes `scrollView.contentOffset` from a click or drag.
    var onUserScroll: (() -> Void)?

    /// Height, in points, of each source line's row.
    var minimapRowHeight: CGFloat = 3
    /// Width, in points, allotted per character column.
    var characterWidth: CGFloat = 1
    /// Horizontal inset before the first block.
    var leadingInset: CGFloat = 4
    /// Horizontal inset kept clear at the trailing edge (the fade lives inside it).
    var trailingInset: CGFloat = 2

    private let hairlineView = UIView()
    private let viewportIndicatorView = UIView()
    private var isDraggingIndicator = false
    private var dragStartLocalY: CGFloat = 0
    private var dragStartContentOffsetY: CGFloat = 0

    private let cache = MinimapRowCache()
    private var palette = MinimapPalette(baseColor: .textColor)
    /// Bumped whenever theme colors change or the effective appearance flips, so the palette and
    /// row cache are rebuilt against fresh colors.
    private var themeGeneration: UInt64 = 0
    private var paletteGeneration: UInt64 = .max

    private struct PaintKey: Hashable {
        let colorIndex: Int
        let fadeStep: Int
    }

    private struct RenderKey: Equatable {
        var offsetY: CGFloat
        var size: CGSize
        var contentGeneration: UInt64
        var contentHeight: CGFloat
        var themeGeneration: UInt64
    }
    private var lastRenderKey: RenderKey?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        viewportIndicatorView.wantsLayer = true
        viewportIndicatorView.layer?.cornerRadius = 3
        viewportIndicatorView.layer?.borderWidth = 1
        viewportIndicatorView.isHidden = true
        hairlineView.isHidden = true
        addSubview(hairlineView)
        addSubview(viewportIndicatorView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isHidden, bounds.width > 0, bounds.height > 0 else {
            hideChrome()
            return
        }
        hairlineView.isHidden = false
        hairlineView.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        layoutViewportIndicator()
    }

    // MARK: - Geometry

    private var maxColumns: Int {
        Int((bounds.width - leadingInset - trailingInset) / max(characterWidth, 0.5))
    }

    private var currentGeometry: MinimapGeometry? {
        guard let source = lineDataSource, let scrollView, bounds.height > 0 else {
            return nil
        }
        let lineManager = source.lineManager
        let estimated = max(lineManager.estimatedLineHeight, 1)
        let inset = source.textContainerInset
        let documentHeight = max(scrollView.contentSize.height, inset.top + lineManager.contentHeight + inset.bottom)
        let geometry = MinimapGeometry(
            boundsHeight: bounds.height,
            viewportHeight: scrollView.bounds.height,
            contentOffsetY: scrollView.visibleContentOffset.y,
            minimumContentOffsetY: scrollView.minimumContentOffset.y,
            maximumContentOffsetY: scrollView.maximumContentOffset.y,
            documentHeight: documentHeight,
            textContainerInsetTop: inset.top,
            scale: minimapRowHeight / estimated,
            minIndicatorHeight: 6
        )
        return geometry.isValid ? geometry : nil
    }

    // MARK: - Drawing

    private struct VisibleLine {
        let line: DocumentLineNode
        let bandY: CGFloat
        let barHeight: CGFloat
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let source = lineDataSource,
              let geometry = currentGeometry,
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let columns = maxColumns
        guard columns > 0 else {
            return
        }
        rebuildPaletteIfNeeded(theme: source.theme)

        let lineManager = source.lineManager
        let estimated = max(lineManager.estimatedLineHeight, 1)
        let visible = visibleLines(source: source, geometry: geometry, estimated: estimated)
        guard !visible.isEmpty else {
            lastRenderKey = makeRenderKey(geometry: geometry, source: source)
            return
        }

        let tabLength = max(source.indentStrategy.tabLength, 1)
        cache.beginFrame(
            contentGeneration: source.stringView.contentGeneration,
            themeGeneration: themeGeneration,
            parseGeneration: source.syntaxParseGeneration,
            maxColumns: columns,
            tabLength: tabLength
        )
        let builder = MinimapRowBuilder(
            maxColumns: columns,
            characterWidth: characterWidth,
            leadingInset: leadingInset,
            tabLength: tabLength
        )
        var rowByLineID: [DocumentLineNodeID: MinimapRow] = [:]
        rowByLineID.reserveCapacity(visible.count)
        var chunkStart = 0
        while chunkStart < visible.count {
            var chunkEnd = chunkStart + 1
            while chunkEnd < visible.count,
                  chunkEnd - chunkStart < 64,
                  visible[chunkEnd].line.row == visible[chunkEnd - 1].line.row + 1 {
                chunkEnd += 1
            }
            resolveRows(visible[chunkStart ..< chunkEnd], source: source, builder: builder, into: &rowByLineID)
            chunkStart = chunkEnd
        }
        cache.endFrame()

        var rectsByKey: [PaintKey: [CGRect]] = [:]
        for entry in visible {
            guard let row = rowByLineID[entry.line.id] else {
                continue
            }
            for segment in row.segments {
                let key = PaintKey(colorIndex: segment.colorIndex, fadeStep: segment.fadeStep)
                rectsByKey[key, default: []].append(CGRect(
                    x: segment.x,
                    y: entry.bandY,
                    width: segment.width,
                    height: entry.barHeight
                ))
            }
        }
        for (key, rects) in rectsByKey {
            let baseColor = key.colorIndex >= 0 && key.colorIndex < palette.colors.count
                ? palette.colors[key.colorIndex]
                : palette.colors[0]
            let cgColor = baseColor.cgColor
            let alpha = MinimapFade.alpha(forStep: key.fadeStep)
            context.setFillColor(alpha < 1 ? (cgColor.copy(alpha: alpha) ?? cgColor) : cgColor)
            context.fill(rects)
        }

        lastRenderKey = makeRenderKey(geometry: geometry, source: source)
        #if DEBUG
        debugLastDrawnRowCount = visible.count
        #endif
    }

    /// Walks the document in y-space (never by row index) so a collapsed fold spanning tens of
    /// thousands of rows costs O(1), not O(hidden lines) — iterating those rows would also thrash
    /// `LineManager`'s handle table and permanently slow every later edit.
    private func visibleLines(source: TextInputView, geometry: MinimapGeometry, estimated: CGFloat) -> [VisibleLine] {
        let lineManager = source.lineManager
        var result: [VisibleLine] = []
        let yRange = geometry.visibleDocumentYRange
        var docY = yRange.lowerBound
        var iterations = 0
        // The y-range naturally holds about `bounds.height / minimapRowHeight` rows; this is only
        // a safety net against a non-advancing lookup, so give it generous slack.
        let iterationLimit = Int(bounds.height / max(minimapRowHeight, 0.5)) * 2 + 64
        while docY <= yRange.upperBound, iterations <= iterationLimit {
            iterations += 1
            guard let line = lineManager.line(containingYOffset: docY) else {
                break
            }
            let height = line.data.lineHeight
            if height > 0, !source.isLineHidden(line.id) {
                let bandY = geometry.bandY(forLineYPosition: line.yPosition)
                let barHeight = max(geometry.bandHeight(forDocumentHeight: min(height, estimated)) - 1, 1)
                if bandY + barHeight >= 0, bandY <= bounds.height {
                    result.append(VisibleLine(line: line, bandY: bandY, barHeight: barHeight))
                }
            }
            // Advance by the line's real height so no short line is skipped; `max(_, 1)` (and the
            // `docY + 1` floor) guarantees forward progress across a run of zero-height folded
            // lines.
            docY = max(line.yPosition + max(height, 1), docY + 1)
        }
        return result
    }

    private func resolveRows(_ slice: ArraySlice<VisibleLine>,
                             source: TextInputView,
                             builder: MinimapRowBuilder,
                             into rowByLineID: inout [DocumentLineNodeID: MinimapRow]) {
        var misses: [DocumentLineNode] = []
        for entry in slice {
            if let cached = cache.cachedRow(for: entry.line.id) {
                rowByLineID[entry.line.id] = cached
            } else {
                misses.append(entry.line)
            }
        }
        guard let first = misses.first, let last = misses.last else {
            return
        }
        let spanStart = first.location
        let spanEnd = last.location + last.data.totalLength
        let spanRange = NSRange(location: spanStart, length: max(0, spanEnd - spanStart))
        guard spanRange.length > 0, spanRange.length <= 1 << 16 else {
            for line in misses {
                rowByLineID[line.id] = flatRow(for: line, source: source, builder: builder)
            }
            return
        }

        switch source.minimapSyntaxAvailability(forUTF16Range: spanRange) {
        case .unavailable:
            for line in misses {
                let row = flatRow(for: line, source: source, builder: builder)
                rowByLineID[line.id] = row
                cache.store(row, for: line.id, provisional: false)
            }
        case .pending:
            for line in misses {
                let row = flatRow(for: line, source: source, builder: builder)
                rowByLineID[line.id] = row
                cache.store(row, for: line.id, provisional: true)
            }
        case .ready:
            source.stringView.prefetch(utf16Range: spanRange)
            guard let text = source.stringView.substring(in: spanRange) else {
                for line in misses {
                    rowByLineID[line.id] = flatRow(for: line, source: source, builder: builder)
                }
                return
            }
            let chars = Array(text.utf16)
            let captures = source.minimapCaptures(inByteRange: ByteRange(utf16Range: spanRange))
            let colored: [(range: Range<Int>, colorIndex: Int)] = captures.compactMap { capture -> (range: Range<Int>, colorIndex: Int)? in
                let range = NSRange(capture.byteRange)
                guard range.length > 0 else {
                    return nil
                }
                let colorIndex = palette.index(forCaptureName: capture.name, theme: source.theme)
                guard colorIndex != palette.baseColorIndex else {
                    return nil
                }
                return (range.location ..< range.location + range.length, colorIndex)
            }
            for line in misses {
                let localStart = line.location - spanStart
                let lineLength = line.data.length
                guard localStart >= 0, localStart + lineLength <= chars.count else {
                    rowByLineID[line.id] = flatRow(for: line, source: source, builder: builder)
                    continue
                }
                let lineSlice = chars[localStart ..< localStart + lineLength]
                let spans: [(range: Range<Int>, colorIndex: Int)] = colored.compactMap { entry -> (range: Range<Int>, colorIndex: Int)? in
                    let lower = max(0, entry.range.lowerBound - line.location)
                    let upper = min(lineLength, entry.range.upperBound - line.location)
                    guard lower < upper else {
                        return nil
                    }
                    return (lower ..< upper, entry.colorIndex)
                }
                let row = builder.makeRow(utf16: lineSlice, colorSpans: spans)
                rowByLineID[line.id] = row
                cache.store(row, for: line.id, provisional: false)
            }
        }
    }

    private func flatRow(for line: DocumentLineNode, source: TextInputView, builder: MinimapRowBuilder) -> MinimapRow {
        let range = NSRange(location: line.location, length: line.data.length)
        guard range.length > 0, let text = source.stringView.substring(in: range) else {
            return .empty
        }
        let units = Array(text.utf16)
        return builder.makeFlatRow(utf16: units[units.startIndex ..< units.endIndex])
    }

    #if DEBUG
    /// Number of source-line rows the last `draw(_:)` touched. Test hook for the folding
    /// regression — a collapsed fold must not inflate this.
    private(set) var debugLastDrawnRowCount = 0
    /// Distinct fill colors interned while building rows. Index 0 is the theme base color;
    /// syntax captures append more. Test hook so we don't have to pixel-sample appearance-adaptive
    /// `NSColor`s through a bitmap (those round to the same 8-bit RGB in some environments).
    var debugPaletteColorCount: Int { palette.colors.count }
    var debugViewportIndicatorHidden: Bool { viewportIndicatorView.isHidden }
    var debugViewportIndicatorFrame: CGRect { viewportIndicatorView.frame }
    #endif

    // MARK: - Invalidation

    private func makeRenderKey(geometry: MinimapGeometry, source: TextInputView) -> RenderKey {
        RenderKey(
            offsetY: geometry.contentOffsetY,
            size: bounds.size,
            contentGeneration: source.stringView.contentGeneration,
            contentHeight: source.lineManager.contentHeight,
            themeGeneration: themeGeneration
        )
    }

    /// Call whenever the document's content, scroll position, or size changes.
    func setNeedsDisplayForContentChange() {
        if let source = lineDataSource, let geometry = currentGeometry {
            let key = makeRenderKey(geometry: geometry, source: source)
            if key != lastRenderKey {
                needsDisplay = true
            }
        } else {
            needsDisplay = true
        }
        layoutViewportIndicator()
    }

    /// Call when a syntax parse finishes so provisional (uncolored) rows recolor next draw.
    func invalidateSyntaxColors() {
        cache.invalidateProvisionalRows()
        lastRenderKey = nil
        needsDisplay = true
    }

    private func rebuildPaletteIfNeeded(theme: Theme) {
        guard paletteGeneration != themeGeneration else {
            return
        }
        palette = MinimapPalette(baseColor: theme.textColor)
        paletteGeneration = themeGeneration
    }

    /// Applies the current theme's colors to the minimap's chrome (background, hairline, and
    /// viewport indicator) and drops the color caches so bars are rebuilt against the new theme.
    func applyTheme() {
        guard let theme = lineDataSource?.theme else {
            return
        }
        backgroundColor = theme.gutterBackgroundColor
        hairlineView.backgroundColor = theme.gutterHairlineColor
        viewportIndicatorView.backgroundColor = theme.selectionColor.withAlphaComponent(0.25)
        applyViewportIndicatorBorderColor(theme: theme)
        themeGeneration &+= 1
        cache.removeAll()
        lastRenderKey = nil
        needsDisplay = true
        layoutViewportIndicator()
    }

    /// `viewportIndicatorView.layer?.borderColor` isn't a `UIView.backgroundColor`, so it isn't
    /// covered by `UIView.viewDidChangeEffectiveAppearance()`'s re-bake — re-apply it here too, on
    /// both theme changes and effective-appearance changes.
    private func applyViewportIndicatorBorderColor(theme: Theme) {
        viewportIndicatorView.layer?.borderColor = theme.selectionColor.withAlphaComponent(0.6).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let theme = lineDataSource?.theme {
            applyViewportIndicatorBorderColor(theme: theme)
        }
        // Theme colors resolve differently under the new appearance — rebuild the palette and
        // every cached row.
        themeGeneration &+= 1
        cache.removeAll()
        lastRenderKey = nil
        if isHidden || bounds.width <= 0 || bounds.height <= 0 {
            hideChrome()
        } else {
            needsDisplay = true
        }
    }

    // MARK: - Viewport indicator

    private func hideChrome() {
        hairlineView.isHidden = true
        hairlineView.frame = .zero
        viewportIndicatorView.isHidden = true
        viewportIndicatorView.frame = .zero
    }

    /// Collapses the overlay immediately so layer-backed chrome cannot linger at the last
    /// trailing-edge frame after the minimap is turned off.
    func collapseOverlay() {
        isHidden = true
        frame = .zero
        hideChrome()
    }

    private func layoutViewportIndicator() {
        guard !isHidden, bounds.width > 0, let geometry = currentGeometry else {
            viewportIndicatorView.isHidden = true
            viewportIndicatorView.frame = .zero
            if isHidden || bounds.width <= 0 || bounds.height <= 0 {
                hairlineView.isHidden = true
                hairlineView.frame = .zero
            }
            return
        }
        viewportIndicatorView.isHidden = false
        viewportIndicatorView.frame = geometry.indicatorRect(width: bounds.width)
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let geometry = currentGeometry, let scrollView else {
            return
        }
        if viewportIndicatorView.frame.contains(point) {
            isDraggingIndicator = true
            dragStartLocalY = point.y
            dragStartContentOffsetY = scrollView.contentOffset.y
        } else {
            isDraggingIndicator = false
            onUserScroll?()
            scrollView.contentOffset = CGPoint(
                x: scrollView.contentOffset.x,
                y: geometry.contentOffsetY(forClickAtLocalY: point.y)
            )
            setNeedsDisplayForContentChange()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingIndicator, let geometry = currentGeometry, let scrollView else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        onUserScroll?()
        scrollView.contentOffset = CGPoint(
            x: scrollView.contentOffset.x,
            y: geometry.contentOffsetY(forDragDelta: point.y - dragStartLocalY, from: dragStartContentOffsetY)
        )
        setNeedsDisplayForContentChange()
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingIndicator = false
    }

    override func scrollWheel(with event: NSEvent) {
        // The minimap doesn't scroll independently — forward wheel events to the real editor.
        scrollView?.scrollWheel(with: event)
    }
}
