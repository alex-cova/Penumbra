import Foundation
@preconcurrency import AppKit
import EditorIntelligence
import simd
// swiftlint:disable file_length

@MainActor
protocol LayoutManagerDelegate: AnyObject {
    func layoutManager(_ layoutManager: LayoutManager, didProposeContentOffsetAdjustment contentOffsetAdjustment: CGPoint)
}

@MainActor
final class LayoutManager {
    weak var delegate: LayoutManagerDelegate?
    weak var gutterParentView: UIView? {
        didSet {
            if gutterParentView != oldValue {
                setupViewHierarchy()
            }
        }
    }
    weak var textInputView: UIView? {
        didSet {
            if textInputView != oldValue {
                setupViewHierarchy()
            }
        }
    }
    var lineManager: LineManager {
        didSet {
            if lineManager !== oldValue {
                foldRibbonView.lineManager = lineManager
                // `setState` replaces the line manager. The separator view holds it weakly, so
                // without this the y positions go nil and no hairline is ever produced.
                methodSeparatorView.lineManager = lineManager
                methodSeparatorView.needsDisplay = true
                setNeedsLayout()
            }
        }
    }
    var stringView: StringView
    var scrollViewWidth: CGFloat = 0
    var viewport: CGRect = .zero
    var languageMode: InternalLanguageMode {
        didSet {
            if languageMode !== oldValue {
                for lineController in lineControllerStorage {
                    lineController.invalidateSyntaxHighlighter()
                    lineController.invalidateSyntaxHighlighting()
                }
            }
        }
    }
    var theme: Theme = DefaultTheme() {
        didSet {
            if theme !== oldValue {
                gutterBackgroundView.backgroundColor = theme.gutterBackgroundColor
                gutterBackgroundView.hairlineColor = theme.gutterHairlineColor
                gutterBackgroundView.hairlineWidth = theme.gutterHairlineWidth
                invisibleCharacterConfiguration.font = theme.font
                invisibleCharacterConfiguration.textColor = theme.invisibleCharactersColor
                gutterSelectionBackgroundView.backgroundColor = theme.selectedLinesGutterBackgroundColor
                lineSelectionBackgroundView.backgroundColor = theme.selectedLineBackgroundColor
                syncMethodSeparatorHairline(
                    color: pageGuideView?.hairlineColor,
                    width: pageGuideView?.hairlineWidth ?? 0
                )
                applyFoldRibbonTheme()
                for lineController in lineControllerStorage {
                    lineController.theme = theme
                    lineController.estimatedLineFragmentHeight = theme.font.totalLineHeight
                    lineController.invalidateSyntaxHighlighting()
                }
                if theme.font != oldValue.font {
                    // Drop the old face's tiles from the shared glyph atlas; the re-typeset above
                    // makes every visible fragment re-extract with the new font.
                    metalRenderer?.handleThemeFontChange(previousFont: oldValue.font as CTFont)
                    if let scale = metalCanvasView?.effectiveBackingScale {
                        metalRenderer?.prewarm(font: theme.font as CTFont, scale: scale)
                    }
                }
                // Dirty only — never layoutIfNeeded here. Theme is assigned from
                // setState during SwiftUI updateNSView; sync layout aborts AppKit.
                setNeedsLayout()
                setNeedsLayoutLineSelection()
            }
        }
    }
    var isEditing = false {
        didSet {
            if isEditing != oldValue {
                updateShownViews()
                updateLineNumberColors()
            }
        }
    }
    var showLineNumbers = false {
        didSet {
            if showLineNumbers != oldValue {
                updateShownViews()
                setNeedsLayout()
            }
        }
    }
    var showFoldingRibbon = false {
        didSet {
            if showFoldingRibbon != oldValue {
                updateShownViews()
                setNeedsLayout()
            }
        }
    }
    weak var foldingController: FoldingController? {
        didSet {
            foldRibbonView.foldingController = foldingController
        }
    }
    weak var focusModeController: FocusModeController?
    var lineSelectionDisplayType: LineSelectionDisplayType = .disabled {
        didSet {
            if lineSelectionDisplayType != oldValue {
                setNeedsLayoutLineSelection()
                updateShownViews()
            }
        }
    }
    var isLineWrappingEnabled = true
    /// Spacing around the text. The left-side spacing defines the distance between the text and the gutter.
    var textContainerInset: UIEdgeInsets = .zero
    var safeAreaInsets: UIEdgeInsets = .zero
    var selectedRange: NSRange? {
        didSet {
            if selectedRange != oldValue {
                updateShownViews()
            }
        }
    }
    var lineHeightMultiplier: CGFloat = 1
    var constrainingLineWidth: CGFloat {
        if isLineWrappingEnabled {
            return scrollViewWidth - leadingLineSpacing - textContainerInset.right - safeAreaInsets.left - safeAreaInsets.right
        } else {
            // Rendering multiple very long lines is very expensive. In order to let the editor remain useable,
            // we set a very high maximum line width when line wrapping is disabled.
            return 10_000
        }
    }
    var markedRange: NSRange? {
        didSet {
            if markedRange != oldValue {
                updateMarkedTextOnVisibleLines()
            }
        }
    }

    // MARK: - Views
    let gutterContainerView = GutterContainerView()
    /// Transparent Metal host. Sits behind `linesContainerView` while Metal is off, in front of it
    /// (where the fragment views would be) once Metal is the active paint backend. Owned by
    /// `TextInputView`.
    weak var metalCanvasView: MetalTextCanvasView? {
        didSet {
            if metalCanvasView !== oldValue {
                setupViewHierarchy()
            }
        }
    }
    weak var pageGuideView: PageGuideView?
    private(set) var paintBackend: LinePaintBackend
    private let cgPaintBackend: CGLinePaintBackend
    private var metalRenderer: MetalRenderer?
    /// `true` when `paintBackend` is the Metal renderer. Flipped by `setMetalRenderingActive(_:)`.
    private(set) var isMetalRenderingActive = false
    private var metalRasterRetryCount = 0
    private static let maxMetalRasterRetries = 40
    /// Lines touched by the latest edit; layout highlights these synchronously so keystrokes
    /// keep syntax colours instead of flashing default `theme.textColor` until async work lands.
    /// Inlay hints of the whole document, sorted by offset (see ``InlayHintIndex/normalized(_:)``).
    /// Lines pick theirs up as they are laid out; setting this re-typesets the lines that had
    /// different ones.
    var inlayHints: [InlayHint] = [] {
        didSet {
            guard inlayHints != oldValue else { return }
            var changedLineIDs: Set<DocumentLineNodeID> = []
            for lineController in lineControllerStorage {
                let line = lineController.line
                let local = InlayHintIndex.localHints(in: inlayHints, lineLocation: line.location, lineLength: line.data.length)
                if local != lineController.inlayHints {
                    lineController.inlayHints = local
                    changedLineIDs.insert(line.id)
                }
            }
            if !changedLineIDs.isEmpty { redisplayLines(withIDs: changedLineIDs) }
            setNeedsLayout()
        }
    }
    private var recentlyEditedLineIDs: Set<DocumentLineNodeID> = []
    private var lineNumberLabelReuseQueue = ViewReuseQueue<DocumentLineNodeID, LineNumberView>()
    private var visibleLineIDs: Set<DocumentLineNodeID> = []
    var currentlyVisibleLineIDs: Set<DocumentLineNodeID> { visibleLineIDs }
    private let linesContainerView = UIView()
    private let gutterBackgroundView = GutterBackgroundView()
    private let lineNumbersContainerView = UIView()
    private let gutterSelectionBackgroundView = UIView()
    private let lineSelectionBackgroundView = UIView()
    private let foldRibbonView = FoldRibbonView()
    private let gutterDecorationView = GutterDecorationView()
    var gutterDecorations: [GutterDecoration] = [] {
        didSet {
            gutterDecorationView.decorations = gutterDecorations
            gutterWidthService.showGutterDecorations = !gutterDecorations.isEmpty
            setNeedsLayout()
        }
    }
    var gutterDecorationHandler: ((Int) -> Void)? {
        didSet { gutterDecorationView.onLineClicked = gutterDecorationHandler }
    }
    let methodSeparatorView = MethodSeparatorView()
    var showMethodSeparators = false {
        didSet {
            if showMethodSeparators != oldValue {
                updateShownViews()
                setNeedsLayout()
            }
        }
    }

    // MARK: - Sizing
    private var leadingLineSpacing: CGFloat {
        if showLineNumbers {
            return gutterWidthService.gutterWidth + textContainerInset.left
        } else {
            return textContainerInset.left
        }
    }
    /// Width of the gutter column, including the leading safe-area inset. This is the region the
    /// Metal canvas (see ``MetalCanvasGeometry``) must never paint over.
    private var totalGutterWidth: CGFloat {
        safeAreaInsets.left + gutterWidthService.gutterWidth
    }
    private var insetViewport: CGRect {
        let x = viewport.minX - textContainerInset.left
        let y = viewport.minY - textContainerInset.top
        let width = viewport.width + textContainerInset.left + textContainerInset.right
        let height = viewport.height + textContainerInset.top + textContainerInset.bottom
        return CGRect(x: x, y: y, width: width, height: height)
    }
    /// Extra vertical space, in points, laid out above and below the visible viewport during
    /// ``layoutLinesInViewport()``. Lines within this band get their line fragments and views
    /// prepared before they're actually visible, so fast scrolling doesn't show a moment of
    /// unlaid-out content at the leading edge. Set to 0 to lay out exactly the visible rect.
    var verticalLayoutPadding: CGFloat = 350
    /// `insetViewport` expanded by ``verticalLayoutPadding`` on the vertical axis. This is the
    /// rect actually used to decide which lines get laid out.
    private var paddedInsetViewport: CGRect {
        insetViewport.insetBy(dx: 0, dy: -verticalLayoutPadding)
    }
    private let contentSizeService: ContentSizeService
    private let gutterWidthService: GutterWidthService
    private let caretRectService: CaretRectService
    private let selectionRectService: SelectionRectService
    private let highlightService: HighlightService

    // MARK: - Rendering
    private let invisibleCharacterConfiguration: InvisibleCharacterConfiguration
    private let lineControllerStorage: LineControllerStorage
    private var needsLayout = false
    private var needsLayoutLineSelection = false

    init(lineManager: LineManager,
         languageMode: InternalLanguageMode,
         stringView: StringView,
         lineControllerStorage: LineControllerStorage,
         contentSizeService: ContentSizeService,
         gutterWidthService: GutterWidthService,
         caretRectService: CaretRectService,
         selectionRectService: SelectionRectService,
         highlightService: HighlightService,
         invisibleCharacterConfiguration: InvisibleCharacterConfiguration) {
        self.lineManager = lineManager
        self.languageMode = languageMode
        self.stringView = stringView
        self.invisibleCharacterConfiguration = invisibleCharacterConfiguration
        self.lineControllerStorage = lineControllerStorage
        self.contentSizeService = contentSizeService
        self.gutterWidthService = gutterWidthService
        self.caretRectService = caretRectService
        self.selectionRectService = selectionRectService
        self.highlightService = highlightService
        let cgPaintBackend = CGLinePaintBackend(linesContainerView: linesContainerView)
        self.cgPaintBackend = cgPaintBackend
        self.paintBackend = cgPaintBackend
        self.linesContainerView.isUserInteractionEnabled = false
        self.lineNumbersContainerView.isUserInteractionEnabled = false
        self.gutterContainerView.isUserInteractionEnabled = false
        self.gutterBackgroundView.isUserInteractionEnabled = false
        self.gutterSelectionBackgroundView.isUserInteractionEnabled = false
        self.lineSelectionBackgroundView.isUserInteractionEnabled = false
        self.foldRibbonView.lineManager = lineManager
        self.gutterDecorationView.lineManager = lineManager
        self.methodSeparatorView.lineManager = lineManager
        // Property default assignment skips didSet — paint chrome colors now so the
        // gutter never appears unstyled (or DefaultTheme near-black) on first layout.
        gutterBackgroundView.backgroundColor = theme.gutterBackgroundColor
        gutterBackgroundView.hairlineColor = theme.gutterHairlineColor
        gutterBackgroundView.hairlineWidth = theme.gutterHairlineWidth
        gutterSelectionBackgroundView.backgroundColor = theme.selectedLinesGutterBackgroundColor
        lineSelectionBackgroundView.backgroundColor = theme.selectedLineBackgroundColor
        syncMethodSeparatorHairline(
            color: pageGuideView?.hairlineColor,
            width: pageGuideView?.hairlineWidth ?? 0
        )
        applyFoldRibbonTheme()
        self.updateShownViews()
        let memoryWarningNotificationName = UIApplication.didReceiveMemoryWarningNotification
        NotificationCenter.default.addObserver(self, selector: #selector(clearMemory), name: memoryWarningNotificationName, object: nil)
    }

    func redisplayVisibleLines() {
        // Dirty only — callers (and TextInputView.layoutSubviews) perform layout.
        setNeedsLayout()
        redisplayLines(withIDs: visibleLineIDs)
        setNeedsDisplayOnLines()
        setNeedsLayout()
    }

    func redisplayLines(withIDs lineIDs: Set<DocumentLineNodeID>, colorShift: (utf16RangeInLine: NSRange, text: String)? = nil) {
        recentlyEditedLineIDs.formUnion(lineIDs)
        for lineID in lineIDs {
            if let lineController = lineControllerStorage[lineID] {
                let usedColorShift: Bool
                if let colorShift, lineIDs.count == 1 {
                    usedColorShift = lineController.applyColorShift(
                        replacing: colorShift.utf16RangeInLine,
                        with: colorShift.text
                    )
                } else {
                    usedColorShift = false
                }
                if !usedColorShift {
                    lineController.invalidateEverything()
                }
                // Only display the line if it's currently visible on the screen. Otherwise it's enough to invalidate it and redisplay it later.
                if visibleLineIDs.contains(lineID) {
                    let lineYPosition = lineController.line.yPosition
                    let lineLocalViewport = CGRect(x: 0, y: lineYPosition, width: insetViewport.width, height: insetViewport.maxY - lineYPosition)
                    lineController.prepareToDisplayString(in: lineLocalViewport, syntaxHighlightAsynchronously: false)
                }
            }
        }
        paintBackend.invalidateGlyphs(forLineIDs: lineIDs)
        if isMetalRenderingActive, let metalCanvasView {
            metalCanvasView.withCoalescedPresent {
                for lineID in lineIDs where visibleLineIDs.contains(lineID) {
                    upsertLineFragmentsForDisplay(lineID: lineID)
                }
            }
        }
    }

    /// Return at end-of-line does not change the edited line's glyphs. The new line also has no
    /// height until it is typeset, so following lines keep their old Y unless a full viewport
    /// layout runs now — waiting for a deferred pass is what left Metal presenting the pre-Return
    /// frame.
    func relayoutVisibleFragmentsAfterLineStructureChange() {
        paintBackend.invalidateForLineStructureChange()
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Re-upsert Metal paint specs after async syntax highlighting refreshed `CTLine` colours.
    ///
    /// Each visible line's highlight completes independently (a separate `Task { @MainActor }`
    /// hop per line, per `LineController`), so this can be called several times in the same
    /// run-loop turn when one parse round finishes N visible lines at once. Deliberately does
    /// *not* call `presentMetalCanvasIfNeeded()` here — `upsertFragment` already calls
    /// `canvasView?.setNeedsDisplay()`, which schedules one deferred, coalesced present per
    /// run-loop turn (`MetalTextCanvasView.scheduleDeferredPresentIfNeeded`). Presenting
    /// synchronously per call would turn that into N separate encode + `waitUntilScheduled`
    /// cycles instead of one.
    func refreshMetalGlyphsAfterSyntaxHighlight(for lineID: DocumentLineNodeID) {
        guard isMetalRenderingActive, visibleLineIDs.contains(lineID) else {
            return
        }
        upsertLineFragmentsForDisplay(lineID: lineID)
    }

    func invalidateSyntaxHighlightingOnVisibleLines() {
        for lineID in visibleLineIDs {
            lineControllerStorage[lineID]?.invalidateSyntaxHighlighting()
        }
    }

    /// Appearance change: glyph instance colors were baked at extract time. Drop cache keys so
    /// the next layout re-extracts against the new `effectiveAppearance`.
    func invalidateMetalGlyphsForAppearanceChange() {
        guard isMetalRenderingActive else {
            return
        }
        paintBackend.invalidateGlyphs(forLineIDs: visibleLineIDs)
        paintBackend.setNeedsDisplay()
    }

    func setNeedsDisplayOnLines() {
        for lineController in lineControllerStorage {
            lineController.setNeedsDisplayOnLineFragmentViews()
        }
        // Display-only invalidation (invisible-character toggles, marked-text changes) does not run
        // `layoutLinesInViewport`. The CG path just re-`draw`s the fragment views; the Metal path
        // has no views, so re-upsert a fresh spec per visible fragment (glyph extract is skipped
        // when neither the `CTLine` identity nor the cull rect changed).
        upsertVisibleFragmentsForDisplayInvalidation()
        paintBackend.setNeedsDisplay()
    }

    /// Glyph instance colors Metal currently holds for `lineID` (or every fragment when `nil`),
    /// empty when Metal is not active. Debug/test only.
    func metalDebugGlyphColors(forLineID lineID: DocumentLineNodeID? = nil) -> [SIMD4<Float>] {
        guard isMetalRenderingActive else {
            return []
        }
        return metalRenderer?.debugGlyphColors(forLineID: lineID) ?? []
    }

    func metalDebugGlyphOrigins(forLineID lineID: DocumentLineNodeID? = nil) -> [SIMD2<Float>] {
        guard isMetalRenderingActive else {
            return []
        }
        return metalRenderer?.debugGlyphOrigins(forLineID: lineID) ?? []
    }

    /// Debug/PerfHarness snapshot of the Metal backend, or `nil` when Metal is not active.
    var metalDebugStats: MetalRenderer.DebugStats? {
        isMetalRenderingActive ? metalRenderer?.debugStats : nil
    }

    var metalPaintGeneration: UInt64 {
        metalRenderer?.paintGeneration ?? 0
    }

    var metalAtlasCensus: (nonzero: Int, total: Int, pages: Int)? {
        guard isMetalRenderingActive else {
            return nil
        }
        return metalRenderer?.atlasCensus()
    }

    /// Swap the paint backend between the CG reuse-queue and the Metal renderer. Returns `true` when
    /// the requested state is in effect afterwards (a `true` request needs a Metal device + canvas).
    @discardableResult
    func setMetalRenderingActive(_ active: Bool) -> Bool {
        if active {
            guard let metalCanvasView else {
                return false
            }
            if metalRenderer == nil {
                metalRenderer = MetalRenderer(canvasView: metalCanvasView)
                metalRenderer?.onAtlasWarmed = { [weak self] in
                    self?.setNeedsLayout()
                    self?.textInputView?.setNeedsLayout()
                    (self?.textInputView as? TextInputView)?.scheduleDeferredLayoutIfNeeded()
                }
            }
            guard let metalRenderer else {
                return false
            }
            guard !isMetalRenderingActive else {
                return true
            }
            cgPaintBackend.removeFragments(ids: cgPaintBackend.trackedFragmentIDs)
            paintBackend = metalRenderer
            isMetalRenderingActive = true
            metalRenderer.prewarm(font: theme.font as CTFont, scale: metalCanvasView.effectiveBackingScale)
        } else {
            guard isMetalRenderingActive else {
                return true
            }
            metalRenderer.map { $0.removeFragments(ids: $0.trackedFragmentIDs) }
            paintBackend = cgPaintBackend
            isMetalRenderingActive = false
        }
        setupViewHierarchy()
        updateShownViews()
        setNeedsLayout()
        return active == isMetalRenderingActive
    }

    /// Copies the right-margin hairline onto method separators. `color == nil` or `width <= 0`
    /// falls back to the theme's page-guide stroke at ``pageGuideHairlineOpacity``.
    func syncMethodSeparatorHairline(color: UIColor?, width: CGFloat) {
        methodSeparatorView.separatorColor = color
            ?? theme.pageGuideHairlineColor.withAlphaComponent(pageGuideHairlineOpacity)
        methodSeparatorView.separatorWidth = width > 0 ? width : theme.pageGuideHairlineWidth
    }

    func textPreview(containing needleRange: NSRange, peekLength: Int = 50) -> TextPreview? {
        let lines = lineManager.lines(in: needleRange)
        guard !lines.isEmpty else {
            return nil
        }
        let firstLine = lines[0]
        let lastLine = lines[lines.count - 1]
        let minimumLocation = firstLine.location
        let maximumLocation = lastLine.location + lastLine.data.length
        let startLocation = max(needleRange.location - peekLength, minimumLocation)
        let endLocation = min(NSMaxRange(needleRange) + peekLength, maximumLocation)
        let previewLength = endLocation - startLocation
        let previewRange = NSRange(location: startLocation, length: previewLength)
        let lineControllers = lines.map { lineControllerStorage.getOrCreateLineController(for: $0) }
        let localNeedleLocation = needleRange.location - startLocation
        let localNeedleLength = min(needleRange.length, previewRange.length)
        let needleInPreviewRange = NSRange(location: localNeedleLocation, length: localNeedleLength)
        return TextPreview(needleRange: needleRange,
                           previewRange: previewRange,
                           needleInPreviewRange: needleInPreviewRange,
                           lineControllers: lineControllers)
    }
}

// MARK: - UITextInput
extension LayoutManager {
    func firstRect(for range: NSRange) -> CGRect {
        guard let line = lineManager.line(containingCharacterAt: range.location) else {
            fatalError("Cannot find first rect.")
        }
        let lineController = lineControllerStorage.getOrCreateLineController(for: line)
        let localRange = NSRange(location: range.location - line.location, length: min(range.length, line.value))
        let lineContentsRect = lineController.firstRect(for: localRange)
        let visibleWidth = viewport.width - gutterWidthService.gutterWidth
        let xPosition = lineContentsRect.minX + textContainerInset.left + gutterWidthService.gutterWidth
        let yPosition = line.yPosition + lineContentsRect.minY + textContainerInset.top
        let width = min(lineContentsRect.width, visibleWidth)
        return CGRect(x: xPosition, y: yPosition, width: width, height: lineContentsRect.height)
    }

    func closestIndex(to point: CGPoint) -> Int? {
        let adjustedXPosition = point.x - leadingLineSpacing
        let adjustedYPosition = point.y - textContainerInset.top
        let adjustedPoint = CGPoint(x: adjustedXPosition, y: adjustedYPosition)
        if let line = lineManager.line(containingYOffset: adjustedPoint.y), let lineController = lineControllerStorage[line.id] {
            return closestIndex(to: adjustedPoint, in: lineController)
        } else if adjustedPoint.y <= 0 {
            let firstLine = lineManager.firstLine
            if let lineController = lineControllerStorage[firstLine.id] {
                return closestIndex(to: adjustedPoint, in: lineController)
            } else {
                return 0
            }
        } else {
            let lastLine = lineManager.lastLine
            if adjustedPoint.y >= lastLine.yPosition, let lineController = lineControllerStorage[lastLine.id] {
                return closestIndex(to: adjustedPoint, in: lineController)
            } else {
                return stringView.length
            }
        }
    }

    private func closestIndex(to point: CGPoint, in lineController: LineController) -> Int {
        let line = lineController.line
        let localPoint = CGPoint(x: point.x, y: point.y - line.yPosition)
        return lineController.closestIndex(to: localPoint)
    }
}

// MARK: - Block Selection
extension LayoutManager {
    /// Row index of the document line at `yPosition` (view-space). Falls back to the first/last
    /// line when `yPosition` falls outside the laid-out content, mirroring `closestIndex(to:)`'s
    /// own y-fallback branches. Used to seed and extend a block/column selection from a mouse point.
    func lineIndex(forYPosition yPosition: CGFloat) -> Int {
        let adjustedYPosition = yPosition - textContainerInset.top
        if let line = lineManager.line(containingYOffset: adjustedYPosition) {
            return line.index
        } else if adjustedYPosition <= 0 {
            return lineManager.firstLine.index
        } else {
            return lineManager.lastLine.index
        }
    }

    /// Character index closest to `xPosition` (view-space) within the first visual line fragment
    /// of the document line at `row`, clamped to that line's own bounds (excluding its line
    /// delimiter). Used by column/block selection, which reasons about specific document rows
    /// rather than a y-position — rows may be off-screen, so this typesets the line on demand via
    /// `prepareLineForDisplay(atLocation:)` rather than relying on it already being laid out.
    func closestIndex(toXPosition xPosition: CGFloat, inLineAtRow row: Int) -> Int {
        let line = lineManager.line(atRow: row)
        prepareLineForDisplay(atLocation: line.location)
        guard let lineController = lineControllerStorage[line.id] else {
            return line.location
        }
        let adjustedXPosition = xPosition - leadingLineSpacing
        let globalIndex = lineController.closestIndex(to: CGPoint(x: adjustedXPosition, y: 0))
        return min(max(globalIndex, line.location), line.location + line.data.length)
    }
}

// MARK: - Layout
extension LayoutManager {
    func setNeedsLayout() {
        needsLayout = true
    }

    func layoutIfNeeded() {
        if needsLayout {
            PenumbraSignposts.event("LayoutManager.layoutStarted")
            needsLayout = false
            foldingController?.recomputeIfNeeded()
            let performLayout = { [self] in
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layoutGutter()
                layoutLineSelection()
                layoutLinesInViewport()
                updateLineNumberColors()
                CATransaction.commit()
            }
            if isMetalRenderingActive, let metalCanvasView {
                // Coalesce every `setNeedsDisplay` this pass triggers (`setViewport`, each
                // `upsertFragment`) into the single present below, run *after* the disableActions
                // transaction. `presentsWithTransaction` commits the drawable at
                // `CATransaction.commit`; disableActions swallows that contents update, which is
                // the blank-editor symptom (offscreen encode still has glyphs, the on-screen
                // `CAMetalLayer` stays clear).
                metalCanvasView.withCoalescedPresent(performLayout)
            } else {
                performLayout()
            }
            scheduleMetalRasterRetryIfNeeded()
            PenumbraSignposts.event("LayoutManager.layoutCompleted")
        }
    }

    /// A layout pass that hit the per-frame glyph raster cap left some visible glyphs un-extracted;
    /// re-drive layout (bounded) so they fill in over the next few passes. Bounded so a viewport
    /// that is genuinely all-cold doesn't spin — the rest fills in on the next real scroll.
    private func scheduleMetalRasterRetryIfNeeded() {
        guard isMetalRenderingActive, metalRenderer?.consumePendingRasterRetry() == true else {
            metalRasterRetryCount = 0
            return
        }
        guard metalRasterRetryCount < Self.maxMetalRasterRetries else {
            return
        }
        metalRasterRetryCount += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.setNeedsLayout()
            self.textInputView?.setNeedsLayout()
        }
    }

    func setNeedsLayoutLineSelection() {
        needsLayoutLineSelection = true
    }

    /// Publish the row set the method-separator overlay should draw.
    func setMethodSeparatorRows(_ rows: Set<Int>) {
        guard rows != methodSeparatorView.separatorRows else {
            return
        }
        methodSeparatorView.separatorRows = rows
        guard isMetalRenderingActive else {
            return
        }
        updateMetalCanvasPaintSpec()
        presentMetalCanvasIfNeeded()
    }

    func layoutLineSelectionIfNeeded() {
        if needsLayoutLineSelection {
            needsLayoutLineSelection = false
            CATransaction.begin()
            CATransaction.setDisableActions(false)
            layoutLineSelection()
            updateLineNumberColors()
            CATransaction.commit()
            updateMetalCanvasPaintSpec()
            presentMetalCanvasIfNeeded()
        }
    }

    private func layoutGutter() {
        let contentSize = contentSizeService.contentSize
        gutterContainerView.frame = CGRect(x: viewport.minX, y: 0, width: totalGutterWidth, height: contentSize.height)
        gutterBackgroundView.frame = CGRect(x: 0, y: viewport.minY, width: totalGutterWidth, height: viewport.height)
        lineNumbersContainerView.frame = CGRect(x: 0, y: 0, width: totalGutterWidth, height: contentSize.height)
        let decorationWidth = gutterWidthService.showGutterDecorations ? gutterWidthService.gutterDecorationColumnWidth : 0
        if gutterWidthService.showGutterDecorations {
            gutterDecorationView.frame = CGRect(x: 0, y: 0, width: decorationWidth, height: contentSize.height)
            gutterDecorationView.textContainerInsetTop = textContainerInset.top
        }
        var interactive: CGRect?
        if showFoldingRibbon {
            let ribbonWidth = gutterWidthService.foldingRibbonWidth
            let ribbonFrame = CGRect(x: totalGutterWidth - ribbonWidth, y: 0, width: ribbonWidth, height: contentSize.height)
            foldRibbonView.frame = ribbonFrame
            foldRibbonView.textContainerInsetTop = textContainerInset.top
            interactive = ribbonFrame
        }
        if gutterWidthService.showGutterDecorations {
            let decorationFrame = CGRect(x: 0, y: 0, width: decorationWidth, height: contentSize.height)
            interactive = interactive.map { $0.union(decorationFrame) } ?? decorationFrame
        }
        gutterContainerView.interactiveRect = interactive
    }

    private func layoutLineSelection() {
        if let rect = getLineSelectionRect() {
            gutterSelectionBackgroundView.frame = CGRect(x: 0, y: rect.minY, width: totalGutterWidth, height: rect.height)
            let lineSelectionBackgroundOrigin = CGPoint(x: viewport.minX + totalGutterWidth, y: rect.minY)
            let lineSelectionBackgroundSize = CGSize(width: scrollViewWidth - gutterWidthService.gutterWidth, height: rect.height)
            lineSelectionBackgroundView.frame = CGRect(origin: lineSelectionBackgroundOrigin, size: lineSelectionBackgroundSize)
        }
    }

    private func getLineSelectionRect() -> CGRect? {
        guard lineSelectionDisplayType.shouldShowLineSelection, var selectedRange = selectedRange else {
            return nil
        }
        guard let (startLine, endLine) = lineManager.startAndEndLine(in: selectedRange) else {
            return nil
        }
        // If the line starts where our selection ends then our selection end son a line break and we will not include the following line.
        var realEndLine = endLine
        if selectedRange.upperBound == endLine.location && startLine !== endLine {
            realEndLine = endLine.previous
            selectedRange = NSRange(location: selectedRange.lowerBound, length: max(selectedRange.length - 1, 0))
        }
        switch lineSelectionDisplayType {
        case .line:
            let minY = startLine.yPosition
            let height = (realEndLine.yPosition + realEndLine.data.lineHeight) - minY
            return CGRect(x: 0, y: textContainerInset.top + minY, width: scrollViewWidth, height: height)
        case .lineFragment:
            let startCaretRect = caretRectService.caretRect(at: selectedRange.lowerBound, allowMovingCaretToNextLineFragment: false)
            let endCaretRect = caretRectService.caretRect(at: selectedRange.upperBound, allowMovingCaretToNextLineFragment: false)
            let startLineFragmentHeight = startCaretRect.height * lineHeightMultiplier
            let endLineFragmentHeight = endCaretRect.height * lineHeightMultiplier
            let minY = startCaretRect.minY - (startLineFragmentHeight - startCaretRect.height) / 2
            let maxY = endCaretRect.maxY + (endLineFragmentHeight - endCaretRect.height) / 2
            return CGRect(x: 0, y: minY, width: scrollViewWidth, height: maxY - minY)
        case .disabled:
            return nil
        }
    }

    /// Typesets only the line containing `location`, without walking every line before it.
    ///
    /// The target line's Y position (`line.yPosition`) is read from the line manager's red-black
    /// tree in O(log n) using each earlier line's currently-known height — which is exact for
    /// lines that have already been laid out, but an estimate for ones that haven't. So a jump to
    /// a distant, never-visited location may land at a slightly imprecise Y offset if earlier
    /// lines wrap differently than estimated; this self-corrects the same way ordinary scrolling
    /// already does, as those lines are eventually measured. This trade-off is what makes
    /// jump-to-location navigation on a large document O(log n) instead of O(location).
    func prepareLineForDisplay(atLocation location: Int) {
        let safeLocation = min(max(location, 0), stringView.length)
        guard let line = lineManager.line(containingCharacterAt: safeLocation) else {
            return
        }
        let lineLocalLocation = min(safeLocation, line.location + line.data.length) - line.location
        let lineController = lineControllerStorage.getOrCreateLineController(for: line)
        lineController.constrainingWidth = constrainingLineWidth
        lineController.prepareToDisplayString(toLocation: lineLocalLocation, syntaxHighlightAsynchronously: true)
        let lineSize = CGSize(width: lineController.lineWidth, height: lineController.lineHeight)
        contentSizeService.setSize(of: lineController.line, to: lineSize)
    }

    /// Vertical center of the visual line fragment containing `location`, in content coordinates.
    func lineAnchorY(at location: Int) -> CGFloat? {
        let safeLocation = min(max(location, 0), stringView.length)
        guard let line = lineManager.line(containingCharacterAt: safeLocation) else {
            return nil
        }
        prepareLineForDisplay(atLocation: safeLocation)
        let lineController = lineControllerStorage.getOrCreateLineController(for: line)
        let lineLocalLocation = min(max(safeLocation - line.location, 0), line.data.length)
        if let fragment = lineController.lineFragmentNode(containingCharacterAt: lineLocalLocation)?.data.lineFragment {
            return textContainerInset.top + line.yPosition + fragment.yPosition + fragment.scaledSize.height / 2
        }
        let lineTop = textContainerInset.top + line.yPosition
        return TypewriterScrollingPolicy.anchorY(lineYPosition: lineTop, lineHeight: lineController.lineHeight)
    }

    // swiftlint:disable:next function_body_length
    private func layoutLinesInViewport() {
        let signpost = PenumbraSignposts.performance.beginInterval("LayoutManager.layoutLinesInViewport")
        defer { PenumbraSignposts.performance.endInterval("LayoutManager.layoutLinesInViewport", signpost) }
        // Immediately bail out from generating lines in a viewport of zero size.
        guard viewport.size.width > 0 && viewport.size.height > 0 else {
            return
        }
        // Position the Metal canvas and hand the backend the current cull rect *before* any
        // `upsertFragment`, so this pass's glyph extract uses the up-to-date `emitRect`.
        layoutMetalCanvas()
        let oldVisibleLineIDs = visibleLineIDs
        let oldVisibleLineFragmentIDs = paintBackend.trackedFragmentIDs
        // Layout lines within a padded band around the viewport, so lines about to scroll into
        // view already have their fragments and views prepared (see verticalLayoutPadding).
        let layoutBounds = paddedInsetViewport
        var nextLine = lineManager.line(containingYOffset: layoutBounds.minY)
        if let startLine = nextLine {
            let endLine = lineManager.line(containingYOffset: layoutBounds.maxY) ?? lineManager.lastLine
            let start = startLine.location
            let end = endLine.location + endLine.data.totalLength
            stringView.prefetch(utf16Range: NSRange(location: start, length: max(0, end - start)))
        }
        var appearedLineIDs: Set<DocumentLineNodeID> = []
        var appearedLineFragmentIDs: Set<LineFragmentID> = []
        var maxY = layoutBounds.minY
        var contentOffsetAdjustmentY: CGFloat = 0
        while let line = nextLine, maxY < layoutBounds.maxY, constrainingLineWidth > 0 {
            // A folded-away line contributes zero height and no views; skip it entirely rather
            // than typesetting it, and move on to the next row without advancing maxY. (The
            // *starting* line for this walk already skips hidden lines for free, since
            // `line(containingYOffset:)` can never land inside a zero-height range — but this
            // walk advances row-by-row from there, so hidden lines in the middle of the visible
            // range need this explicit check.)
            if let foldingController, foldingController.isLineHidden(line.id) {
                nextLine = line.index < lineManager.lineCount - 1 ? lineManager.line(atRow: line.index + 1) : nil
                continue
            }
            appearedLineIDs.insert(line.id)
            // Prepare to line controller to display text.
            let lineLocalViewport = CGRect(x: 0, y: maxY, width: layoutBounds.width, height: layoutBounds.maxY - maxY)
            let lineController = lineControllerStorage.getOrCreateLineController(for: line)
            let oldLineHeight = lineController.lineHeight
            lineController.constrainingWidth = constrainingLineWidth
            // Set before the line is prepared: a change re-typesets it with the hints' room.
            lineController.inlayHints = InlayHintIndex.localHints(
                in: inlayHints, lineLocation: line.location, lineLength: line.data.length
            )
            let highlightAsynchronously = !recentlyEditedLineIDs.contains(line.id)
            lineController.prepareToDisplayString(in: lineLocalViewport, syntaxHighlightAsynchronously: highlightAsynchronously)
            layoutLineNumberView(for: line)
            // Layout line fragments ("sublines") in the line until we have filled the viewport.
            let lineYPosition = line.yPosition
            let lineFragmentControllers = lineController.lineFragmentControllers(in: layoutBounds)
            let collapsedFold = foldingController?.collapsedFold(withHeaderLineID: line.id)
            let lineRange = NSRange(location: line.location, length: line.data.length)
            let focusedLineRanges = focusModeController?.focusedRanges(forLineWithID: line.id, lineRange: lineRange) ?? []
            // Apply marked text before upsert so `LineFragmentPaintSpec.decorations` is current.
            if let markedRange = markedRange {
                let markedLineRange = NSRange(location: lineController.line.location, length: lineController.line.data.totalLength)
                let localMarkedRange = markedRange.local(to: markedLineRange)
                lineController.setMarkedTextOnLineFragments(localMarkedRange)
            } else {
                lineController.setMarkedTextOnLineFragments(nil)
            }
            for (lineFragmentIndex, lineFragmentController) in lineFragmentControllers.enumerated() {
                let lineFragment = lineFragmentController.lineFragment
                var lineFragmentFrame: CGRect = .zero
                appearedLineFragmentIDs.insert(lineFragment.id)
                lineFragmentController.highlightedRangeFragments = highlightService.highlightedRangeFragments(for: lineFragment,
                                                                                                              inLineWithID: line.id)
                lineFragmentController.unfocusedAlpha = focusModeController?.effectiveUnfocusedAlpha ?? 1
                lineFragmentController.focusedRanges = focusedLineRanges.compactMap { range in
                    range.overlaps(lineFragment.range) ? range.capped(to: lineFragment.range) : nil
                }
                lineFragmentController.foldPlaceholderText = (collapsedFold != nil && lineFragmentIndex == lineFragmentControllers.count - 1)
                    ? "\u{22EF}"
                    : nil
                lineFragmentController.inlayHints = lineController.inlayHints.filter { hint in
                    hint.localOffset > lineFragment.range.location && hint.localOffset <= lineFragment.range.upperBound
                }
                layoutLineFragmentView(
                    for: lineFragmentController,
                    lineID: line.id,
                    lineLocation: line.location,
                    lineYPosition: lineYPosition,
                    isLastLineFragment: lineFragmentIndex == lineFragmentControllers.count - 1,
                    lineEndsWithLineBreak: line.data.delimiterLength > 0,
                    lineFragmentFrame: &lineFragmentFrame
                )
                maxY = lineFragmentFrame.maxY
            }
            if lineFragmentControllers.isEmpty {
                // An empty line (Return at end-of-line) has no fragment controllers, but it still
                // occupies estimated line height. Advance maxY so the viewport walk continues;
                // stopping here used to treat every following line as scrolled-out and Metal
                // dropped their glyphs until a resize.
                maxY = max(maxY, textContainerInset.top + line.yPosition + lineController.lineHeight)
            }
            let lineSize = CGSize(width: lineController.lineWidth, height: lineController.lineHeight)
            contentSizeService.setSize(of: lineController.line, to: lineSize)
            let isSizingLineAboveTopEdge = line.yPosition < insetViewport.minY + textContainerInset.top
            if isSizingLineAboveTopEdge && lineController.isFinishedTypesetting {
                contentOffsetAdjustmentY += lineController.lineHeight - oldLineHeight
            }
            if line.index < lineManager.lineCount - 1 && maxY < layoutBounds.maxY {
                nextLine = lineManager.line(atRow: line.index + 1)
            } else {
                nextLine = nil
            }
        }
        let contentSize = contentSizeService.contentSize
        linesContainerView.frame = CGRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)
        if showMethodSeparators {
            let separatorWidth = max(contentSize.width, scrollViewWidth)
            methodSeparatorView.textContainerInsetTop = textContainerInset.top
            methodSeparatorView.frame = CGRect(x: 0, y: 0, width: separatorWidth, height: contentSize.height)
        }
        // The canvas was positioned before line heights settled. Replay the underlay so method
        // separators use the frame just assigned, matching the page-guide hairline.
        updateMetalCanvasPaintSpec()
        // Update the visible lines and line fragments. Clean up everything that is not in the viewport anymore.
        visibleLineIDs = appearedLineIDs
        let disappearedLineIDs = oldVisibleLineIDs.subtracting(appearedLineIDs)
        let disappearedLineFragmentIDs = oldVisibleLineFragmentIDs.subtracting(appearedLineFragmentIDs)
        for disappearedLineID in disappearedLineIDs {
            let lineController = lineControllerStorage[disappearedLineID]
            lineController?.cancelSyntaxHighlighting()
        }
        lineNumberLabelReuseQueue.enqueueViews(withKeys: disappearedLineIDs)
        paintBackend.removeFragments(ids: disappearedLineFragmentIDs)
        // Adjust the content offset on the Y-axis if necessary.
        if contentOffsetAdjustmentY != 0 {
            let contentOffsetAdjustment = CGPoint(x: 0, y: contentOffsetAdjustmentY)
            delegate?.layoutManager(self, didProposeContentOffsetAdjustment: contentOffsetAdjustment)
        }
        recentlyEditedLineIDs.removeAll()
        // Present is deferred to `layoutIfNeeded` after this disableActions transaction
        // commits — see `presentMetalCanvasIfNeeded()`.
    }

    private func presentMetalCanvasIfNeeded() {
        guard isMetalRenderingActive else {
            return
        }
        metalCanvasView?.presentIfDirty()
    }

    private func layoutLineNumberView(for line: DocumentLineNode) {
        let lineNumberView = lineNumberLabelReuseQueue.dequeueView(forKey: line.id)
        if lineNumberView.superview == nil {
            lineNumbersContainerView.addSubview(lineNumberView)
        }
        let lineController = lineControllerStorage.getOrCreateLineController(for: line)
        let fontLineHeight = theme.lineNumberFont.lineHeight
        let decorationWidth = gutterWidthService.showGutterDecorations ? gutterWidthService.gutterDecorationColumnWidth : 0
        let xPosition = safeAreaInsets.left + gutterWidthService.gutterLeadingPadding + decorationWidth
        var yPosition = textContainerInset.top + line.yPosition
        if lineController.numberOfLineFragments > 1 {
            // There are more than one line fragments, so we align the line number at the top.
            yPosition += (fontLineHeight * lineHeightMultiplier - fontLineHeight) / 2
        } else {
            // There's a single line fragment, so we center the line number in the height of the line.
            yPosition += (lineController.lineHeight - fontLineHeight) / 2
        }
        lineNumberView.text = "\(line.index + 1)"
        lineNumberView.font = theme.lineNumberFont
        lineNumberView.textColor = theme.lineNumberColor
        lineNumberView.frame = CGRect(x: xPosition, y: yPosition, width: gutterWidthService.lineNumberWidth, height: fontLineHeight)
    }

    /// Move the transparent Metal canvas to the visible text rect (view-follows-viewport) and give
    /// the paint backend the viewport / cull rect / backing scale for this layout pass. No-op unless
    /// Metal is the active backend.
    ///
    /// The canvas is inset by ``totalGutterWidth`` so its opaque background solid never paints
    /// over the gutter (line numbers, fold ribbon) — see ``MetalCanvasGeometry``. Without this,
    /// `bringSubviewToFront(gutterContainerView)` in `TextView.layoutSubviews` cannot rescue the
    /// gutter: it is a no-op there because the gutter's superview is the scrolling document
    /// container, not the scroll view the canvas is a fixed overlay of.
    private func layoutMetalCanvas() {
        guard isMetalRenderingActive, let metalCanvasView else {
            return
        }
        // Overlay on the scroll view covers the visible rect and stays put while
        // `canvasFrame` (content space) tracks the viewport for projection.
        // Inside the clip view the same layer does not composite.
        let isScrollViewOverlay = metalCanvasView.superview === gutterParentView
        let (viewFrame, canvasFrame) = MetalCanvasGeometry.frames(
            viewport: viewport,
            gutterWidth: totalGutterWidth,
            isScrollViewOverlay: isScrollViewOverlay
        )
        metalCanvasView.frame = viewFrame
        paintBackend.setViewport(canvasFrame, canvasFrame: canvasFrame, scale: metalCanvasView.effectiveBackingScale)
        updateMetalCanvasPaintSpec()
    }

    private func updateMetalCanvasPaintSpec() {
        guard isMetalRenderingActive, let metalCanvasView else {
            return
        }
        let isScrollViewOverlay = metalCanvasView.superview === gutterParentView
        let (_, canvasFrame) = MetalCanvasGeometry.frames(
            viewport: viewport,
            gutterWidth: totalGutterWidth,
            isScrollViewOverlay: isScrollViewOverlay
        )
        let visiblePageGuide = pageGuideView.flatMap { view in
            view.superview == nil || view.isHidden ? nil : view
        }
        paintBackend.setCanvasPaintSpec(CanvasPaintSpec(
            frame: canvasFrame,
            backgroundColor: textInputView?.backgroundColor ?? .textBackgroundColor,
            lineSelectionRect: lineSelectionBackgroundView.isHidden ? nil : getLineSelectionRect(),
            lineSelectionColor: theme.selectedLineBackgroundColor,
            pageGuideFrame: visiblePageGuide?.frame,
            pageGuideHairlineWidth: visiblePageGuide?.hairlineWidth ?? 0,
            pageGuideHairlineColor: visiblePageGuide?.hairlineColor ?? .clear,
            pageGuideShadingColor: visiblePageGuide?.shadingColor ?? .clear,
            showsPageGuideShading: visiblePageGuide?.showReformattingGuideShading ?? false,
            methodSeparatorFrames: methodSeparatorFrames(in: canvasFrame),
            methodSeparatorColor: methodSeparatorView.separatorColor,
            appearance: textInputView?.effectiveAppearance,
            colorSpace: metalCanvasView.effectiveColorSpace
        ))
    }

    /// Visible method-separator hairlines in content space. Empty when the feature is off; the
    /// AppKit view is hidden while Metal is active, so visibility is `showMethodSeparators`.
    private func methodSeparatorFrames(in canvasFrame: CGRect) -> [CGRect] {
        guard showMethodSeparators else {
            return []
        }
        return methodSeparatorView.separatorLineFrames(clip: canvasFrame.insetBy(dx: -2, dy: -2))
    }

    /// Rebuild the paint spec for every visible line fragment without running a full viewport
    /// layout. Used by display-only invalidation paths (`setNeedsDisplayOnLines`,
    /// `updateMarkedTextOnVisibleLines`). Cheap for the CG backend (it already re-`draw`s its views
    /// from `setNeedsDisplayOnLines`) so it only runs when Metal is active.
    private func upsertVisibleFragmentsForDisplayInvalidation() {
        guard isMetalRenderingActive else {
            return
        }
        for lineID in visibleLineIDs {
            upsertLineFragmentsForDisplay(lineID: lineID)
        }
        presentMetalCanvasIfNeeded()
    }

    private func upsertLineFragmentsForDisplay(lineID: DocumentLineNodeID) {
        guard isMetalRenderingActive, let lineController = lineControllerStorage[lineID] else {
            return
        }
        let layoutBounds = paddedInsetViewport
        let line = lineController.line
        let lineYPosition = line.yPosition
        let controllers = lineController.lineFragmentControllers(in: layoutBounds)
        for (index, lineFragmentController) in controllers.enumerated() {
            var frame: CGRect = .zero
            layoutLineFragmentView(
                for: lineFragmentController,
                lineID: lineID,
                lineLocation: line.location,
                lineYPosition: lineYPosition,
                isLastLineFragment: index == controllers.count - 1,
                lineEndsWithLineBreak: line.data.delimiterLength > 0,
                lineFragmentFrame: &frame
            )
        }
    }

    /// Whether any invisible-character marker could be visible. Skips the (potentially large)
    /// per-fragment substring fetch when the feature is entirely off.
    private var invisibleCharactersActive: Bool {
        let configuration = invisibleCharacterConfiguration
        return configuration.showTabs
            || configuration.showSpaces
            || configuration.showNonBreakingSpaces
            || configuration.showLineBreaks
            || configuration.showSoftLineBreaks
            || !configuration.warningCharacters.isEmpty
    }

    private func layoutLineFragmentView(
        for lineFragmentController: LineFragmentController,
        lineID: DocumentLineNodeID,
        lineLocation: Int,
        lineYPosition: CGFloat,
        isLastLineFragment: Bool,
        lineEndsWithLineBreak: Bool,
        lineFragmentFrame: inout CGRect
    ) {
        let lineFragment = lineFragmentController.lineFragment
        let lineFragmentOrigin = CGPoint(x: leadingLineSpacing, y: textContainerInset.top + lineYPosition + lineFragment.yPosition)
        let lineFragmentWidth = contentSizeService.contentWidth - leadingLineSpacing - textContainerInset.right
        let lineFragmentSize = CGSize(width: lineFragmentWidth, height: lineFragment.scaledSize.height)
        lineFragmentFrame = CGRect(origin: lineFragmentOrigin, size: lineFragmentSize)
        var invisibles = InvisibleCharacterLayout.empty
        if invisibleCharactersActive {
            let fragmentRange = NSRange(location: lineLocation + lineFragment.visibleRange.location,
                                       length: lineFragment.visibleRange.length)
            if let fragmentString = stringView.substring(in: fragmentRange) {
                invisibles = InvisibleCharacterLayout.resolve(
                    fragmentString: fragmentString,
                    lineFragment: lineFragment,
                    configuration: invisibleCharacterConfiguration
                )
            }
        }
        let spec = LineFragmentPaintSpec(
            id: lineFragment.id,
            lineID: lineID,
            frame: lineFragmentFrame,
            line: lineFragment.line,
            descent: lineFragment.descent,
            baseSize: lineFragment.baseSize,
            scaledSize: lineFragment.scaledSize,
            decorations: LineFragmentDecorations(
                highlighted: lineFragmentController.highlightedRangeFragments,
                markedRange: lineFragmentController.markedRange,
                markedColor: lineFragmentController.markedTextBackgroundColor,
                markedRadius: lineFragmentController.markedTextBackgroundCornerRadius,
                unfocusedAlpha: lineFragmentController.unfocusedAlpha,
                focusedRanges: lineFragmentController.focusedRanges,
                foldPlaceholder: lineFragmentController.foldPlaceholderText,
                foldPlaceholderColor: lineFragmentController.foldPlaceholderColor,
                foldPlaceholderBackgroundColor: lineFragmentController.foldPlaceholderBackgroundColor,
                inlayHints: lineFragmentController.inlayHints,
                fragmentRangeUpperBound: lineFragment.range.upperBound,
                endsWithLineBreak: isLastLineFragment && lineEndsWithLineBreak,
                invisibles: invisibles,
                invisibleFont: invisibleCharacterConfiguration.font,
                invisibleTextColor: invisibleCharacterConfiguration.textColor,
                invisibleWarningColor: invisibleCharacterConfiguration.warningBorderColor
            ),
            fallbackFont: theme.font as CTFont,
            fallbackColor: theme.textColor,
            appearance: textInputView?.effectiveAppearance,
            colorSpace: metalCanvasView?.effectiveColorSpace ?? .sRGB,
            lineRevision: lineFragment.revision,
            isSyntaxHighlightPending: lineControllerStorage[lineID]?.isSyntaxHighlightPending ?? false
        )
        paintBackend.upsertFragment(spec)
        if let lineFragmentView = cgPaintBackend.lineFragmentView(for: lineFragment.id) {
            lineFragmentController.lineFragmentView = lineFragmentView
        }
    }

    private func updateLineNumberColors() {
        let visibleViews = lineNumberLabelReuseQueue.visibleViews
        let selectionFrame = gutterSelectionBackgroundView.frame
        let isSelectionVisible = !gutterSelectionBackgroundView.isHidden
        for (_, lineNumberView) in visibleViews {
            if isSelectionVisible {
                let lineNumberFrame = lineNumberView.frame
                let isInSelection = lineNumberFrame.midY >= selectionFrame.minY && lineNumberFrame.midY <= selectionFrame.maxY
                lineNumberView.textColor = isInSelection && isEditing ? theme.selectedLinesLineNumberColor : theme.lineNumberColor
            } else {
                lineNumberView.textColor = theme.lineNumberColor
            }
        }
    }

    private func setupViewHierarchy() {
        // Remove views from view hierarchy
        lineSelectionBackgroundView.removeFromSuperview()
        methodSeparatorView.removeFromSuperview()
        metalCanvasView?.removeFromSuperview()
        linesContainerView.removeFromSuperview()
        gutterContainerView.removeFromSuperview()
        gutterBackgroundView.removeFromSuperview()
        gutterSelectionBackgroundView.removeFromSuperview()
        lineNumbersContainerView.removeFromSuperview()
        foldRibbonView.removeFromSuperview()
        gutterDecorationView.removeFromSuperview()
        paintBackend.removeFragments(ids: paintBackend.trackedFragmentIDs)
        // Add views to view hierarchy. When Metal is off the canvas sits *behind* the fragment
        // views (which paint the glyphs). When Metal is active it is a viewport-sized overlay on
        // the scroll view (`gutterParentView`) — a `CAMetalLayer` inside `NSClipView` does not
        // composite, which is the blank-editor symptom.
        textInputView?.addSubview(lineSelectionBackgroundView)
        // Behind the glyph canvas (and its selection overlay), in front of the line-selection band.
        textInputView?.addSubview(methodSeparatorView)
        if isMetalRenderingActive {
            textInputView?.addSubview(linesContainerView)
            addMetalCanvasOverlay()
        } else {
            if let metalCanvasView {
                textInputView?.addSubview(metalCanvasView)
            }
            textInputView?.addSubview(linesContainerView)
        }
        gutterParentView?.addSubview(gutterContainerView)
        gutterContainerView.addSubview(gutterBackgroundView)
        gutterContainerView.addSubview(gutterSelectionBackgroundView)
        gutterContainerView.addSubview(gutterDecorationView)
        gutterContainerView.addSubview(lineNumbersContainerView)
        gutterContainerView.addSubview(foldRibbonView)
    }

    private func addMetalCanvasOverlay() {
        guard let metalCanvasView else {
            return
        }
        if let scrollView = gutterParentView as? UIScrollView {
            scrollView.addFixedOverlaySubview(metalCanvasView)
        } else if let gutterParentView {
            gutterParentView.addSubview(metalCanvasView)
        } else {
            textInputView?.addSubview(metalCanvasView)
        }
    }

    /// Re-applies gutter visibility and schedules layout. Use after ``TextView/setState(_:addUndoAction:)``
    /// or other wholesale state swaps that can leave line-number views out of sync even when
    /// ``showLineNumbers`` stays `true` (its `didSet` does not re-fire for an unchanged value).
    func refreshGutterChrome() {
        updateShownViews()
        setNeedsLayout()
    }

    private func updateShownViews() {
        let selectedLength = selectedRange?.length ?? 0
        gutterBackgroundView.isHidden = !showLineNumbers
        lineNumbersContainerView.isHidden = !showLineNumbers
        foldRibbonView.isHidden = !showFoldingRibbon
        gutterDecorationView.isHidden = gutterDecorations.isEmpty
        // Metal paints the hairline on the canvas. The AppKit view would sit under that opaque layer.
        methodSeparatorView.isHidden = !showMethodSeparators || isMetalRenderingActive
        gutterSelectionBackgroundView.isHidden = !lineSelectionDisplayType.shouldShowLineSelection || !showLineNumbers || !isEditing
        lineSelectionBackgroundView.isHidden = !lineSelectionDisplayType.shouldShowLineSelection || !isEditing || selectedLength > 0
    }

    private func applyFoldRibbonTheme() {
        foldRibbonView.markerColor = theme.lineNumberColor
        foldRibbonView.collapsedMarkerColor = theme.selectedLinesGutterBackgroundColor.withAlphaComponent(1)
        foldRibbonView.chevronColor = theme.textColor
    }
}

// MARK: - Marked Text
private extension LayoutManager {
    private func updateMarkedTextOnVisibleLines() {
        for lineID in visibleLineIDs {
            if let lineController = lineControllerStorage[lineID] {
                if let markedRange = markedRange {
                    let lineRange = NSRange(location: lineController.line.location, length: lineController.line.data.totalLength)
                    let localMarkedRange = markedRange.local(to: lineRange)
                    lineController.setMarkedTextOnLineFragments(localMarkedRange)
                } else {
                    lineController.setMarkedTextOnLineFragments(nil)
                }
            }
        }
        // `markedRange` didSet takes this path with no `layoutLinesInViewport`; refresh the Metal
        // paint specs so `unmarkText` and marked-range edits are not lost (no ID-only invalidate).
        upsertVisibleFragmentsForDisplayInvalidation()
        paintBackend.setNeedsDisplay()
    }
}

// MARK: - Memory Management
private extension LayoutManager {
    @objc private func clearMemory() {
        lineControllerStorage.removeAllLineControllers(exceptLinesWithID: visibleLineIDs)
        contentSizeService.removeLineWidths(exceptLinesWithID: visibleLineIDs)
    }
}
