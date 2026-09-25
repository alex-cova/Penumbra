import Foundation
@preconcurrency import AppKit
// swiftlint:disable file_length
import Combine
import EditorIntelligence
import simd

@MainActor
protocol TextInputViewDelegate: AnyObject {
    func textInputViewWillBeginEditing(_ view: TextInputView)
    func textInputViewDidBeginEditing(_ view: TextInputView)
    func textInputViewDidEndEditing(_ view: TextInputView)
    func textInputViewDidCancelBeginEditing(_ view: TextInputView)
    func textInputViewDidChange(_ view: TextInputView)
    func textInputViewDidChangeSelection(_ view: TextInputView)
    func textInputView(_ view: TextInputView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool
    func textInputViewDidInvalidateContentSize(_ view: TextInputView)
    func textInputViewDidRequestLayoutFlush(_ view: TextInputView)
    func textInputView(_ view: TextInputView, didProposeContentOffsetAdjustment contentOffsetAdjustment: CGPoint)
    func textInputViewDidChangeGutterWidth(_ view: TextInputView)
    func textInputViewDidBeginFloatingCursor(_ view: TextInputView)
    func textInputViewDidEndFloatingCursor(_ view: TextInputView)
    func textInputViewDidUpdateMarkedRange(_ view: TextInputView)
    func textInputView(_ view: TextInputView, canReplaceTextIn highlightedRange: HighlightedRange) -> Bool
    func textInputView(_ view: TextInputView, replaceTextIn highlightedRange: HighlightedRange)
    func textInputViewIsSelectable(_ view: TextInputView) -> Bool
    func textInputViewIsEditable(_ view: TextInputView) -> Bool
    func textInputView(_ view: TextInputView, didRequestSelectionInteraction enabled: Bool)
    func textInputViewDidRequestToggleFindPanel(_ view: TextInputView, mode: FindPanelMode)
    func textInputView(_ view: TextInputView, shouldInterceptKeyDown event: NSEvent) -> Bool
    func textInputView(_ view: TextInputView, didReceiveKeyDown event: NSEvent)
    /// Asks the host to perform a keymap action the editor core does not handle itself
    /// (e.g. `.searchEverywhere`, `.goToDefinition`). Return `true` if consumed.
    func textInputView(_ view: TextInputView, didRequestAction action: EditorActionID) -> Bool
    func textInputViewDidReceiveCaretRepositioningClick(_ view: TextInputView)
    func textInputViewDidFinishSyntaxParse(_ view: TextInputView)
    func textInputView(_ view: TextInputView, didChangeContent change: TextContentChange)
}

// swiftlint:disable:next type_body_length
final class TextInputView: UIView, UITextInput {
    /// Modifier changes (Command pressed or released) for Cmd-hover navigation. The text input
    /// is first responder, so it — not the enclosing scroll view — receives `flagsChanged`.
    var onFlagsChanged: ((NSEvent) -> Void)?
    /// Fired after every `insertText(_:)` / `deleteBackward()`, including auto-paired characters
    /// whose insertion bypasses the editor delegate. Completion keys its auto-popup off this.
    var onTypingEvent: ((TextViewTypingEvent) -> Void)?

    // MARK: - UITextInput
    var selectedTextRange: UITextRange? {
        get {
            if let range = _selectedRange {
                return IndexedRange(range)
            } else {
                return nil
            }
        }
        set {
            // We should not use this setter. It's intended for UIKit to use. It'll invoke the setter in various scenarios, for example when navigating the text using the keyboard.
            // On the iOS 16 beta, UIKit may pass an NSRange with a negatives length (e.g. {4, -2}) when double tapping to select text. This will cause a crash when UIKit later attempts to use the selected range with NSString's -substringWithRange:. This can be tested with a string containing the following three lines:
            //    A
            //
            //    A
            // Placing the character on the second line, which is empty, and double tapping several times on the empty line to select text will cause the editor to crash. To work around this we take the non-negative value of the selected range. Last tested on August 30th, 2022.
                let newRange = (newValue as? IndexedRange)?.range.nonNegativeLength
                let sanitizedRange = sanitizedSelection(newRange)
                if sanitizedRange != _selectedRange || multiSelectionController.hasMultipleSelections {
                notifyDelegateAboutSelectionChangeInLayoutSubviews = true
                // The logic for determining whether or not to notify the input delegate is based on advice provided by Alexander Blach, developer of Textastic.
                var shouldNotifyInputDelegate = false
                if didCallPositionFromPositionInDirectionWithOffset {
                    shouldNotifyInputDelegate = true
                    didCallPositionFromPositionInDirectionWithOffset = false
                }
                // This is a consequence of our workaround that ensures multi-stage input, such as when entering Korean,
                // works correctly. The workaround causes bugs when selecting words using Shift + Option + Arrow Keys
                // followed by Shift + Arrow Keys if we do not treat it as a special case.
                // The consequence of not having this workaround is that Shift + Arrow Keys may adjust the wrong end of
                // the selected text when followed by navigating between word boundaries usign Shift + Option + Arrow Keys.
                if customTokenizer.didCallPositionFromPositionToWordBoundary && !didCallDeleteBackward {
                    shouldNotifyInputDelegate = true
                    customTokenizer.didCallPositionFromPositionToWordBoundary = false
                }
                didCallDeleteBackward = false
                notifyInputDelegateAboutSelectionChangeInLayoutSubviews = !shouldNotifyInputDelegate
                if shouldNotifyInputDelegate {
                    inputDelegate?.selectionWillChange(self)
                }
                if !isApplyingMultipleSelectionUpdate {
                    multiSelectionController.setSelections(sanitizedRange.map { [$0] } ?? [])
                }
                _selectedRange = sanitizedRange
                if !isApplyingSnippetSelection && !isApplyingMultipleSelectionUpdate {
                    invalidateSnippetSessionIfSelectionLeftStops(sanitizedRange.map { [$0] } ?? [])
                }
                if shouldNotifyInputDelegate {
                    inputDelegate?.selectionDidChange(self)
                }
            }
        }
    }
    private(set) var markedTextRange: UITextRange? {
        get {
            if let imeMarkedRange = imeMarkedRange {
                return IndexedRange(imeMarkedRange)
            } else {
                return nil
            }
        }
        set {
            imeMarkedRange = (newValue as? IndexedRange)?.range.nonNegativeLength
        }
    }
    var markedTextStyle: [NSAttributedString.Key: Any]?
    var beginningOfDocument: UITextPosition {
        IndexedPosition(index: 0)
    }
    var endOfDocument: UITextPosition {
        IndexedPosition(index: stringView.length)
    }
    weak var inputDelegate: UITextInputDelegate?
    var hasText: Bool {
        stringView.length > 0
    }
    var tokenizer: UITextInputTokenizer {
        customTokenizer
    }
    private lazy var customTokenizer = TextInputStringTokenizer(textInput: self,
                                                                stringView: stringView,
                                                                lineManager: lineManager,
                                                                lineControllerStorage: lineControllerStorage)
    var autocorrectionType: UITextAutocorrectionType = .default
    var autocapitalizationType: UITextAutocapitalizationType = .sentences
    var smartQuotesType: UITextSmartQuotesType = .default
    var smartDashesType: UITextSmartDashesType = .default
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .default
    var spellCheckingType: UITextSpellCheckingType = .default
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .default
    var returnKeyType: UIReturnKeyType = .default
    @objc var insertionPointColor: UIColor = .label {
        didSet {
            if insertionPointColor != oldValue {
                selectionOverlayController.updateColors()
                selectionOverlayController.updateLayout()
            }
        }
    }
    @objc var selectionBarColor: UIColor = .label {
        didSet {
            if selectionBarColor != oldValue {
                selectionOverlayController.updateColors()
            }
        }
    }
    @objc var selectionHighlightColor: UIColor = UIColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 1) {
        didSet {
            if selectionHighlightColor != oldValue {
                // Colors only — do not call updateLayout(). Theme is often applied
                // mid-setState after stringView is swapped but before lineManager is,
                // and caretRect(at:) force-unwraps a line lookup that can fail then.
                selectionOverlayController.updateColors()
            }
        }
    }
    var isEditing = false {
        didSet {
            if isEditing != oldValue {
                layoutManager.isEditing = isEditing
                selectionOverlayController.editingDidChange(isEditing: isEditing)
            }
        }
    }
    override var undoManager: UndoManager? {
        timedUndoManager
    }

    // MARK: - Appearance
    var theme: Theme {
        didSet {
            applyThemeToChildren()
        }
    }
    var showLineNumbers = false {
        didSet {
            if showLineNumbers != oldValue {
                caretRectService.showLineNumbers = showLineNumbers
                gutterWidthService.showLineNumbers = showLineNumbers
                layoutManager.showLineNumbers = showLineNumbers
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    /// Display-only labels drawn inline (see ``InlayHint``). They are kept where they are through
    /// edits, and dropped when the document is replaced.
    var inlayHints: [InlayHint] = [] {
        didSet {
            if inlayHints != oldValue {
                layoutManager.inlayHints = InlayHintIndex.normalized(inlayHints)
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var isLineFoldingEnabled = false {
        didSet {
            if isLineFoldingEnabled != oldValue {
                foldingController.isEnabled = isLineFoldingEnabled
                gutterWidthService.showFoldingRibbon = isLineFoldingEnabled
                layoutManager.showFoldingRibbon = isLineFoldingEnabled
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var isFocusModeEnabled = false {
        didSet {
            if isFocusModeEnabled != oldValue {
                focusModeController.isEnabled = isFocusModeEnabled
                updateFocusModeIfNeeded()
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var focusGranularity: FocusGranularity {
        get {
            focusModeController.granularity
        }
        set {
            if newValue != focusModeController.granularity {
                focusModeController.granularity = newValue
                updateFocusModeIfNeeded()
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var unfocusedTextAlpha: CGFloat {
        get {
            focusModeController.unfocusedAlpha
        }
        set {
            let clamped = min(max(newValue, 0), 1)
            if clamped != focusModeController.unfocusedAlpha {
                focusModeController.unfocusedAlpha = clamped
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var focusedRanges: [NSRange] {
        focusModeController.focusedRanges
    }
    var lineSelectionDisplayType: LineSelectionDisplayType {
        get {
            layoutManager.lineSelectionDisplayType
        }
        set {
            layoutManager.lineSelectionDisplayType = newValue
            layoutManager.setNeedsLayout()
            setNeedsLayout()
            scheduleDeferredLayoutIfNeeded()
        }
    }
    var showTabs: Bool {
        get {
            invisibleCharacterConfiguration.showTabs
        }
        set {
            if newValue != invisibleCharacterConfiguration.showTabs {
                invisibleCharacterConfiguration.showTabs = newValue
                layoutManager.setNeedsDisplayOnLines()
            }
        }
    }
    var showSpaces: Bool {
        get {
            invisibleCharacterConfiguration.showSpaces
        }
        set {
            if newValue != invisibleCharacterConfiguration.showSpaces {
                invisibleCharacterConfiguration.showSpaces = newValue
                layoutManager.setNeedsDisplayOnLines()
            }
        }
    }
    var showNonBreakingSpaces: Bool {
        get {
            invisibleCharacterConfiguration.showNonBreakingSpaces
        }
        set {
            if newValue != invisibleCharacterConfiguration.showNonBreakingSpaces {
                invisibleCharacterConfiguration.showNonBreakingSpaces = newValue
                layoutManager.setNeedsDisplayOnLines()
            }
        }
    }
    var showLineBreaks: Bool {
        get {
            invisibleCharacterConfiguration.showLineBreaks
        }
        set {
            if newValue != invisibleCharacterConfiguration.showLineBreaks {
                invisibleCharacterConfiguration.showLineBreaks = newValue
                invalidateLines()
                layoutManager.setNeedsLayout()
                layoutManager.setNeedsDisplayOnLines()
                setNeedsLayout()
            }
        }
    }
    var showSoftLineBreaks: Bool {
        get {
            invisibleCharacterConfiguration.showSoftLineBreaks
        }
        set {
            if newValue != invisibleCharacterConfiguration.showSoftLineBreaks {
                invisibleCharacterConfiguration.showSoftLineBreaks = newValue
                invalidateLines()
                layoutManager.setNeedsLayout()
                layoutManager.setNeedsDisplayOnLines()
                setNeedsLayout()
            }
        }
    }
    var warningCharacters: Set<Character> {
        get {
            invisibleCharacterConfiguration.warningCharacters
        }
        set {
            if newValue != invisibleCharacterConfiguration.warningCharacters {
                invisibleCharacterConfiguration.warningCharacters = newValue
                layoutManager.setNeedsDisplayOnLines()
            }
        }
    }
    var tabSymbol: String {
        get {
            invisibleCharacterConfiguration.tabSymbol
        }
        set {
            if newValue != invisibleCharacterConfiguration.tabSymbol {
                invisibleCharacterConfiguration.tabSymbol = newValue
                layoutManager.setNeedsDisplayOnLines()
            }
        }
    }
    var spaceSymbol: String {
        get {
            invisibleCharacterConfiguration.spaceSymbol
        }
        set {
            if newValue != invisibleCharacterConfiguration.spaceSymbol {
                invisibleCharacterConfiguration.spaceSymbol = newValue
                layoutManager.setNeedsDisplayOnLines()
            }
        }
    }
    var nonBreakingSpaceSymbol: String {
        get {
            invisibleCharacterConfiguration.nonBreakingSpaceSymbol
        }
        set {
            if newValue != invisibleCharacterConfiguration.nonBreakingSpaceSymbol {
                invisibleCharacterConfiguration.nonBreakingSpaceSymbol = newValue
                layoutManager.setNeedsDisplayOnLines()
            }
        }
    }
    var lineBreakSymbol: String {
        get {
            invisibleCharacterConfiguration.lineBreakSymbol
        }
        set {
            if newValue != invisibleCharacterConfiguration.lineBreakSymbol {
                invisibleCharacterConfiguration.lineBreakSymbol = newValue
                layoutManager.setNeedsDisplayOnLines()
            }
        }
    }
    var softLineBreakSymbol: String {
        get {
            invisibleCharacterConfiguration.softLineBreakSymbol
        }
        set {
            if newValue != invisibleCharacterConfiguration.softLineBreakSymbol {
                invisibleCharacterConfiguration.softLineBreakSymbol = newValue
                layoutManager.setNeedsDisplayOnLines()
            }
        }
    }
    var indentStrategy: IndentStrategy = .tab(length: 2) {
        didSet {
            if indentStrategy != oldValue {
                indentController.indentStrategy = indentStrategy
                layoutManager.setNeedsLayout()
                setNeedsLayout()
                // Do not call layoutIfNeeded() here — SwiftUI updateNSView often
                // assigns indentStrategy mid-pass; forcing layout aborts AppKit.
            }
        }
    }
    var gutterLeadingPadding: CGFloat = 8 {
        didSet {
            if gutterLeadingPadding != oldValue {
                gutterWidthService.gutterLeadingPadding = gutterLeadingPadding
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var gutterTrailingPadding: CGFloat = 6 {
        didSet {
            if gutterTrailingPadding != oldValue {
                gutterWidthService.gutterTrailingPadding = gutterTrailingPadding
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var gutterMinimumCharacterCount: Int = 3 {
        didSet {
            if gutterMinimumCharacterCount != oldValue {
                gutterWidthService.gutterMinimumCharacterCount = gutterMinimumCharacterCount
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var textContainerInset: UIEdgeInsets {
        get {
            layoutManager.textContainerInset
        }
        set {
            if newValue != layoutManager.textContainerInset {
                caretRectService.textContainerInset = newValue
                selectionRectService.textContainerInset = newValue
                contentSizeService.textContainerInset = newValue
                layoutManager.textContainerInset = newValue
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var isLineWrappingEnabled: Bool {
        get {
            layoutManager.isLineWrappingEnabled
        }
        set {
            if newValue != layoutManager.isLineWrappingEnabled {
                contentSizeService.isLineWrappingEnabled = newValue
                layoutManager.isLineWrappingEnabled = newValue
                invalidateLines()
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var lineBreakMode: LineBreakMode = .byWordWrapping {
        didSet {
            if lineBreakMode != oldValue {
                invalidateLines()
                contentSizeService.invalidateContentSize()
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var gutterWidth: CGFloat {
        gutterWidthService.gutterWidth
    }
    var lineHeightMultiplier: CGFloat = 1 {
        didSet {
            if lineHeightMultiplier != oldValue {
                selectionRectService.lineHeightMultiplier = lineHeightMultiplier
                layoutManager.lineHeightMultiplier = lineHeightMultiplier
                invalidateLines()
                lineManager.estimatedLineHeight = estimatedLineHeight
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var kern: CGFloat = 0 {
        didSet {
            if kern != oldValue {
                invalidateLines()
                pageGuideController.kern = kern
                contentSizeService.invalidateContentSize()
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    var characterPairs: [CharacterPair] = [] {
        didSet {
            maximumLeadingCharacterPairComponentLength = characterPairs.map(\.leading.utf16.count).max() ?? 0
        }
    }
    var characterPairTrailingComponentDeletionMode: CharacterPairTrailingComponentDeletionMode = .disabled
    var enterHandlerDelegates: [EnterHandlerDelegate] {
        get { indentController.enterHandlerDelegates }
        set { indentController.enterHandlerDelegates = newValue }
    }
    var showPageGuide = false {
        didSet {
            if showPageGuide != oldValue {
                if showPageGuide {
                    addSubview(pageGuideController.guideView)
                    sendSubviewToBack(pageGuideController.guideView)
                    setNeedsLayout()
                } else {
                    pageGuideController.guideView.removeFromSuperview()
                    setNeedsLayout()
                }
                layoutManager.setNeedsLayout()
                scheduleDeferredLayoutIfNeeded()
            }
        }
    }
    /// Host-controlled Metal rendering preference. Defaults to `true` in production and `false`
    /// under XCTest; still gated by `MetalActivation.resolved` (needs a device, honours the
    /// `PenumbraMetalRendering` kill switch).
    var isMetalRenderingEnabled = MetalActivation.defaultPropertyValue {
        didSet {
            if isMetalRenderingEnabled != oldValue {
                refreshMetalActivation()
            }
        }
    }
    /// `true` when this instance is currently presenting the Metal canvas.
    private(set) var isMetalRenderingActive = false
    var onMetalRenderingFailure: ((String) -> Void)?
    let metalCanvasView = MetalTextCanvasView(frame: .zero)

    /// Backing-scale change: the glyph atlas keys embed the scale, so trigger a relayout that
    /// re-hands the new scale to the renderer (which drops the atlas and re-extracts).
    func handleBackingPropertiesChange() {
        layoutManager.setNeedsLayout()
        setNeedsLayout()
        scheduleDeferredLayoutIfNeeded()
    }

    /// `UIView.layout` does not recurse into children, and SwiftUI / Auto Layout hosts often
    /// do not call `layoutIfNeeded` on `TextInputView` after `setNeedsLayout`. Without a
    /// deferred flush, Metal glyph upserts and `presentIfDirty` wait until a resize forces
    /// `TextView.layoutSubviews`.
    func scheduleDeferredLayoutIfNeeded() {
        guard !deferredLayoutScheduled else {
            return
        }
        PenumbraSignposts.event("TextInputView.deferredLayoutScheduled")
        deferredLayoutScheduled = true
        if let delegate {
            delegate.textInputViewDidRequestLayoutFlush(self)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.performDeferredLayoutFlush()
        }
    }

    private var deferredLayoutScheduled = false

    func performDeferredLayoutFlush() {
        guard deferredLayoutScheduled else {
            return
        }
        PenumbraSignposts.event("TextInputView.deferredLayoutFlushed")
        deferredLayoutScheduled = false
        setNeedsLayout()
        layoutSubtreeIfNeeded()
        layoutIfNeeded()
        metalCanvasView.presentIfDirty()
    }

    func placeSelectionChromeAboveMetalCanvas() {
        selectionOverlayController.placeAboveMetalCanvas()
    }

    /// Debug/PerfHarness snapshot of the Metal backend, or `nil` when Metal is inactive.
    var metalDebugStats: MetalRenderer.DebugStats? {
        layoutManager.metalDebugStats
    }

    var metalPaintGeneration: UInt64 {
        layoutManager.metalPaintGeneration
    }

    var metalAtlasCensus: (nonzero: Int, total: Int, pages: Int)? {
        layoutManager.metalAtlasCensus
    }

    /// Glyph instance colors Metal currently holds for the line at `location` (or every fragment
    /// when `location` is `nil`). Debug/test only.
    func metalDebugGlyphColors(atLocation location: Int? = nil) -> [SIMD4<Float>] {
        let lineID = location.flatMap { lineManager.line(containingCharacterAt: $0)?.id }
        return layoutManager.metalDebugGlyphColors(forLineID: lineID)
    }

    func metalDebugGlyphOrigins(atLocation location: Int? = nil) -> [SIMD2<Float>] {
        let lineID = location.flatMap { lineManager.line(containingCharacterAt: $0)?.id }
        return layoutManager.metalDebugGlyphOrigins(forLineID: lineID)
    }

    /// Offscreen render of the opaque Metal glyph canvas. Snapshot tests / PerfHarness.
    func captureMetalSnapshot() -> NSBitmapImageRep? {
        guard isMetalRenderingActive else {
            return nil
        }
        return metalCanvasView.captureSnapshot()
    }

    /// Presented drawable readback. Requires `allowsMetalDrawableCapture` before init.
    func captureMetalPresentedLayer() -> NSBitmapImageRep? {
        guard isMetalRenderingActive else {
            return nil
        }
        return metalCanvasView.capturePresentedLayer()
    }

    var pageGuideColumn: Int {
        get {
            pageGuideController.column
        }
        set {
            if newValue != pageGuideController.column {
                pageGuideController.column = newValue
                layoutManager.setNeedsLayout()
                setNeedsLayout()
                scheduleDeferredLayoutIfNeeded()
            }
        }
    }
    var showReformattingGuideShading: Bool {
        get {
            pageGuideController.guideView.showReformattingGuideShading
        }
        set {
            pageGuideController.guideView.showReformattingGuideShading = newValue
            layoutManager.setNeedsLayout()
            setNeedsLayout()
            scheduleDeferredLayoutIfNeeded()
        }
    }
    private var estimatedLineHeight: CGFloat {
        theme.font.totalLineHeight * lineHeightMultiplier
    }
    var highlightedRanges: [HighlightedRange] {
        get {
            emphasisManager.userHighlightedRanges
        }
        set {
            if newValue != emphasisManager.userHighlightedRanges {
                emphasisManager.userHighlightedRanges = newValue
                layoutManager.setNeedsLayout()
                setNeedsLayout()
            }
        }
    }
    let emphasisManager = EmphasisManager()
    var diagnostics: [TextViewDiagnostic] {
        get {
            diagnosticEmphasisController.diagnostics
        }
        set {
            diagnosticEmphasisController.setDiagnostics(newValue)
        }
    }
    var bracketPairEmphasis: BracketPairEmphasis?

    // MARK: - Contents
    weak var delegate: TextInputViewDelegate?
    var string: NSString {
        get {
            stringView.string
        }
        set {
            if newValue != stringView.string {
                stringView.string = newValue
                lineManager.rebuild()
                if let oldSelectedRange = selection {
                    inputDelegate?.selectionWillChange(self)
                    selection = safeSelectionRange(from: oldSelectedRange)
                    inputDelegate?.selectionDidChange(self)
                }
                // `rebuild()` recycles `DocumentLineNodeID`s (they restart at 1), and this setter
                // mutates `stringView` / `lineManager` in place rather than swapping in fresh
                // objects the way `setState` does — so the identity-triggered didSets that would
                // normally drop these caches never fire. Clear them explicitly, or a recycled id
                // resurrects the previous document's typeset line (stale `attributedString`,
                // line fragments, height), which paints old glyphs at the new lines' positions.
                lineControllerStorage.removeAllLineControllers()
                contentSizeService.reset()
                gutterWidthService.invalidateLineNumberWidth()
                invalidateLines()
                layoutManager.setNeedsLayout()
                setNeedsLayout()
                if !preserveUndoStackWhenSettingString {
                    undoManager?.removeAllActions()
                }
                startFullParse()
            }
        }
    }
    var viewport: CGRect {
        get {
            layoutManager.viewport
        }
        set {
            if newValue != layoutManager.viewport {
                layoutManager.viewport = newValue
                layoutManager.setNeedsLayout()
                // Must dirty the view: UIView.layout does not recurse into children,
                // and scroll updates contentOffset → viewport without a parent layout
                // pass. Without this, layoutLinesInViewport never runs and scrolled
                // regions stay blank.
                setNeedsLayout()
                ensureViewportSyntaxParse()
            }
        }
    }
    var scrollViewWidth: CGFloat = 0 {
        didSet {
            if scrollViewWidth != oldValue {
                contentSizeService.scrollViewWidth = scrollViewWidth
                layoutManager.scrollViewWidth = scrollViewWidth
                // Assigned from TextView.layoutSubviews — defer line invalidation so we
                // do not rebuild fragments mid-pass.
                if isLineWrappingEnabled {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.invalidateLines()
                        self.layoutManager.setNeedsLayout()
                        self.setNeedsLayout()
                    }
                }
            }
        }
    }
    var contentSize: CGSize {
        contentSizeService.contentSize
    }
    @nonobjc var selection: NSRange? {
        get {
            _selectedRange
        }
        set {
            let sanitizedRange = sanitizedSelection(newValue)
            if sanitizedRange != _selectedRange || multiSelectionController.hasMultipleSelections {
                if !isApplyingMultipleSelectionUpdate {
                    multiSelectionController.setSelections(sanitizedRange.map { [$0] } ?? [])
                }
                _selectedRange = sanitizedRange
                if !isApplyingSnippetSelection && !isApplyingMultipleSelectionUpdate {
                    invalidateSnippetSessionIfSelectionLeftStops(sanitizedRange.map { [$0] } ?? [])
                }
                // Defer host notification — callers often assign selection during
                // setState / updateNSView / layout, and sync callbacks re-enter AppKit.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.textInputViewDidChangeSelection(self)
                }
            }
        }
    }

    var selectedRanges: [NSRange] {
        get {
            if multiSelectionController.selections.isEmpty {
                return selection.map { [$0] } ?? []
            }
            return multiSelectionController.selections
        }
        set {
            applySelectedRanges(newValue)
        }
    }

    var isMultiCursorActive: Bool {
        multiSelectionController.hasMultipleSelections
    }

    private var _selectedRange: NSRange? {
        didSet {
            if _selectedRange != oldValue {
                if !isApplyingMultipleSelectionUpdate,
                   let selectedRange = _selectedRange,
                   multiSelectionController.selections != [selectedRange] {
                    multiSelectionController.setSelections([selectedRange])
                }
                if !isApplyingBlockSelectionUpdate, blockSelectionController.isActive, !blockSelectionController.isStickyModeEnabled {
                    blockSelectionController.end()
                }
                layoutManager.selectedRange = _selectedRange
                layoutManager.setNeedsLayoutLineSelection()
                selectionOverlayController.selectionDidChange()
                if let location = _selectedRange?.location {
                    bracketMatchingController.characterPairs = characterPairs
                    bracketMatchingController.emphasisStyle = bracketPairEmphasis
                    bracketMatchingController.emphasizePairs(at: location)
                } else {
                    bracketMatchingController.clearEmphasis()
                }
                occurrenceHighlightController.selectionDidChange(
                    selectedRange: _selectedRange,
                    isMultiCaret: isMultiCursorActive
                )
                updateFocusModeIfNeeded()
                // The caret overlay and the current-line bar do not need a viewport walk, so draw
                // them now. `setNeedsLayout()` is still required: `layoutSubviews` delivers the
                // deferred selection notifications, and it only walks the viewport when the
                // layout manager itself needs layout.
                layoutManager.layoutLineSelectionIfNeeded()
                setNeedsLayout()
            }
        }
    }
    var canBecomeFirstResponder: Bool {
        true
    }
    weak var gutterParentView: UIView? {
        get {
            layoutManager.gutterParentView
        }
        set {
            layoutManager.gutterParentView = newValue
            updateSelectionOverlayPresentationHost()
        }
    }
    var scrollViewSafeAreaInsets: UIEdgeInsets = .zero {
        didSet {
            if scrollViewSafeAreaInsets != oldValue {
                layoutManager.safeAreaInsets = scrollViewSafeAreaInsets
            }
        }
    }
    var gutterContainerView: UIView {
        layoutManager.gutterContainerView
    }
    var isFileBacked: Bool {
        stringView.isFileBacked
    }
    var documentLength: Int {
        stringView.length
    }
    /// Host-supplied colours painted over the tree-sitter ones (see `TextView.setSemanticHighlights`).
    let semanticHighlights = SemanticHighlightStore()
    private(set) var stringView = StringView() {
        didSet {
            if stringView !== oldValue {
                caretRectService.stringView = stringView
                lineManager.stringView = stringView
                lineControllerFactory.stringView = stringView
                lineControllerStorage.stringView = stringView
                layoutManager.stringView = stringView
                indentController.stringView = stringView
                lineMovementController.stringView = stringView
                customTokenizer.stringView = stringView
                foldingController.stringView = stringView
                focusModeController.stringView = stringView
                occurrenceHighlightController.stringView = stringView
            }
        }
    }
    private(set) var lineManager: LineManager {
        didSet {
            if lineManager !== oldValue {
                indentController.lineManager = lineManager
                lineMovementController.lineManager = lineManager
                gutterWidthService.lineManager = lineManager
                contentSizeService.lineManager = lineManager
                caretRectService.lineManager = lineManager
                selectionRectService.lineManager = lineManager
                highlightService.lineManager = lineManager
                customTokenizer.lineManager = lineManager
                foldingController.lineManager = lineManager
                foldingController.setNeedsRecompute()
                focusModeController.lineManager = lineManager
            }
        }
    }
    var viewHierarchyContainsCaret: Bool {
        selectionOverlayController.isEnabled && isEditing
    }

    func setSelectionOverlayEnabled(_ enabled: Bool) {
        selectionOverlayController.isEnabled = enabled
        if enabled {
            selectionOverlayController.updateLayout()
        }
    }

    func enableSelectionCursorBlinks() {
        selectionOverlayController.enableCursorBlinks()
    }
    var lineEndings: LineEnding = .lf
    private(set) var isRestoringPreviouslyDeletedText = false

    // MARK: - Private
    private var languageMode: InternalLanguageMode = PlainTextInternalLanguageMode() {
        didSet {
            if languageMode !== oldValue {
                indentController.languageMode = languageMode
                if let treeSitterLanguageMode = languageMode as? TreeSitterInternalLanguageMode {
                    treeSitterLanguageMode.delegate = self
                    treeSitterFoldProvider.languageMode = treeSitterLanguageMode
                    foldingController.foldProvider = treeSitterFoldProvider
                    treeSitterFoldProvider.invalidate()
                    foldingController.setNeedsRecompute()
                    methodSeparatorController.languageMode = treeSitterLanguageMode
                } else {
                    foldingController.foldProvider = LineIndentationFoldProvider()
                    methodSeparatorController.languageMode = nil
                }
                methodSeparatorController.recompute()
            }
        }
    }
    /// Bumped on every ``setState`` / ``setLanguageMode`` so a stale deferred parse cannot
    /// invalidate highlighting or notify after the view has moved on to a newer document.
    /// Readable module-wide so the minimap can negative-cache a "no syntax yet" answer without
    /// re-querying every frame.
    private(set) var syntaxParseGeneration = 0
    private var syntaxParsePolicy: SyntaxParsePolicy = .eager
    private var lastReplaceEditRange = NSRange(location: 0, length: 0)
    private var lastReplaceNewString = ""
    private var hasNotifiedSyntaxParse = false
    /// Rows edited since the last successful background parse. Recoloring only these, plus the
    /// rows tree-sitter reports, keeps a finished parse from re-extracting every visible Metal glyph.
    private var rowsEditedSinceSyntaxParse = Set<Int>()
    /// A line was inserted or removed since the last parse, so row numbers recorded before it
    /// are stale. The next parse recolors every visible line and rescans all separators.
    private var rowsShiftedSinceSyntaxParse = false

    /// Bumped when the minimap's cached rows can't be trusted line by line (a document swap, an
    /// edit made outside `replaceText`, a parse without a tree diff), so it drops every row.
    private(set) var minimapDocumentEpoch: UInt64 = 0
    /// Lines whose minimap row is stale since the minimap last drew. Previously every keystroke,
    /// and again every parse after it, flushed the whole minimap cache and re-queried tree-sitter
    /// for every visible minimap row on the main thread (~18% of main-thread time while typing).
    private var minimapDirtyLineIDs = Set<DocumentLineNodeID>()
    /// `stringView.contentGeneration` as of the last change the dirty set accounts for.
    private var minimapKnownContentGeneration: UInt64?

    /// Lines to recolour in the minimap, cleared on read. Bumps ``minimapDocumentEpoch`` first if
    /// the text changed in a way the dirty set doesn't cover.
    func takeMinimapDirtyLineIDs() -> Set<DocumentLineNodeID> {
        let generation = stringView.contentGeneration
        if generation != minimapKnownContentGeneration {
            invalidateAllMinimapRows()
            minimapKnownContentGeneration = generation
        }
        defer { minimapDirtyLineIDs.removeAll(keepingCapacity: true) }
        return minimapDirtyLineIDs
    }

    private func invalidateAllMinimapRows() {
        minimapDocumentEpoch &+= 1
        minimapDirtyLineIDs.removeAll(keepingCapacity: true)
    }

    /// Window last handed to ``startViewportParse``. Prevents layout + `contentOffset` from
    /// cancelling the same in-flight expansion by starting it twice.
    private var inFlightViewportParseRange: NSRange?
    private let lineControllerFactory: LineControllerFactory
    private let lineControllerStorage: LineControllerStorage
    var lineControllerCount: Int { lineControllerStorage.numberOfLineControllers }
    private let layoutManager: LayoutManager
    private let timedUndoManager = TimedUndoManager()
    private let indentController: IndentController
    private let lineMovementController: LineMovementController
    private let pageGuideController = PageGuideController()
    private let gutterWidthService: GutterWidthService
    private let contentSizeService: ContentSizeService
    private let caretRectService: CaretRectService
    private let selectionRectService: SelectionRectService
    private var selectionOverlayController: SelectionOverlayController!
    private let bracketMatchingController: BracketMatchingController
    private let diagnosticEmphasisController = DiagnosticEmphasisController()
    private let multiSelectionController = MultiSelectionController()
    let semanticSelectionController = SemanticSelectionController()
    private var isApplyingMultipleSelectionUpdate = false
    private var snippetSession: SnippetSession?
    private var isApplyingSnippetSelection = false
    let blockSelectionController = BlockSelectionController()
    private var isApplyingBlockSelectionUpdate = false
    /// Set for the duration of a multi-caret batch operation that goes through
    /// `IndentControllerDelegate` (currently `insertLineBreakAtAllSelections()`), so the delegate
    /// callback can tell `replaceText` what the whole caret set should roll back to on undo,
    /// instead of the single range it would otherwise infer from `selection`.
    private var pendingMultiSelectionUndoRestore: (ranges: [NSRange], primaryIndex: Int)?
    private let highlightService: HighlightService
    private let foldingController: FoldingController
    private let focusModeController: FocusModeController
    private let treeSitterFoldProvider = TreeSitterLineFoldProvider()
    let methodSeparatorController = MethodSeparatorController()
    let occurrenceHighlightController: OccurrenceHighlightController
    /// Resolved per-language behaviour. Pushed from ``TextView`` whenever the identifier or
    /// registry changes; drives method separators and occurrence highlighting.
    var languageConfiguration: LanguageConfiguration? {
        didSet {
            methodSeparatorController.configuration = languageConfiguration
            occurrenceHighlightController.configuration = languageConfiguration
            methodSeparatorController.recompute()
            occurrenceHighlightController.selectionDidChange(
                selectedRange: selectedRanges.first,
                isMultiCaret: isMultiCursorActive
            )
        }
    }
    var showMethodSeparators: Bool {
        get {
            layoutManager.showMethodSeparators
        }
        set {
            layoutManager.showMethodSeparators = newValue
            methodSeparatorController.isEnabled = newValue
        }
    }
    var highlightsOccurrencesOfSelection: Bool {
        get {
            occurrenceHighlightController.isEnabled
        }
        set {
            occurrenceHighlightController.isEnabled = newValue
            if newValue {
                occurrenceHighlightController.selectionDidChange(
                    selectedRange: selectedRanges.first,
                    isMultiCaret: isMultiCursorActive
                )
            }
        }
    }
    private let invisibleCharacterConfiguration = InvisibleCharacterConfiguration()
    var imeMarkedRange: NSRange? {
        get {
            layoutManager.markedRange
        }
        set {
            layoutManager.markedRange = newValue
        }
    }
    private var floatingCaretView: FloatingCaretView?
    private var insertionPointColorBeforeFloatingBegan: UIColor = .label
    private var maximumLeadingCharacterPairComponentLength = 0
    private var hasPendingFullLayout = false
    private let editMenuController = EditMenuController()
    private var notifyInputDelegateAboutSelectionChangeInLayoutSubviews = false
    private var notifyDelegateAboutSelectionChangeInLayoutSubviews = false
    private var didCallPositionFromPositionInDirectionWithOffset = false
    private var didCallDeleteBackward = false
    private var hasDeletedTextWithPendingLayoutSubviews = false
    private var preserveUndoStackWhenSettingString = false
    private var cancellables: [AnyCancellable] = []
    var selectionAnchor: Int?
    var isMouseSelecting = false
    /// An Option-click's point, held until `mouseDragged`/`mouseUp` resolve whether it was a
    /// click (add a caret) or a drag (start a block/column selection). See
    /// `TextInputView+MouseKeyboard.swift`.
    var pendingOptionClickPoint: CGPoint?
    /// Active keystroke → action bindings. Set from ``TextView/keymap``.
    var keymap: Keymap = .default_ {
        didSet { keymapDispatcher.reset() }
    }
    /// Resolves key events against ``keymap``, including two-step chords (e.g. ⌘K ⌘D).
    var keymapDispatcher = KeymapDispatcher()
    /// Detects a double tap of bare Shift for Search Everywhere.
    var doubleShiftDetector = DoubleModifierDetector()

    // MARK: - Lifecycle
    init(theme: Theme) {
        self.theme = theme
        lineManager = LineManager(stringView: stringView)
        highlightService = HighlightService(lineManager: lineManager)
        occurrenceHighlightController = OccurrenceHighlightController(stringView: stringView, theme: theme)
        bracketMatchingController = BracketMatchingController(stringView: stringView)
        lineControllerFactory = LineControllerFactory(stringView: stringView,
                                                      highlightService: highlightService,
                                                      invisibleCharacterConfiguration: invisibleCharacterConfiguration)
        lineControllerStorage = LineControllerStorage(stringView: stringView, lineControllerFactory: lineControllerFactory)
        gutterWidthService = GutterWidthService(lineManager: lineManager)
        contentSizeService = ContentSizeService(lineManager: lineManager,
                                                lineControllerStorage: lineControllerStorage,
                                                gutterWidthService: gutterWidthService,
                                                invisibleCharacterConfiguration: invisibleCharacterConfiguration)
        caretRectService = CaretRectService(stringView: stringView,
                                            lineManager: lineManager,
                                            lineControllerStorage: lineControllerStorage,
                                            gutterWidthService: gutterWidthService)
        selectionRectService = SelectionRectService(lineManager: lineManager,
                                                    contentSizeService: contentSizeService,
                                                    gutterWidthService: gutterWidthService,
                                                    caretRectService: caretRectService)
        foldingController = FoldingController(lineManager: lineManager,
                                              stringView: stringView,
                                              lineControllerStorage: lineControllerStorage,
                                              contentSizeService: contentSizeService)
        focusModeController = FocusModeController(lineManager: lineManager, stringView: stringView)
        layoutManager = LayoutManager(lineManager: lineManager,
                                      languageMode: languageMode,
                                      stringView: stringView,
                                      lineControllerStorage: lineControllerStorage,
                                      contentSizeService: contentSizeService,
                                      gutterWidthService: gutterWidthService,
                                      caretRectService: caretRectService,
                                      selectionRectService: selectionRectService,
                                      highlightService: highlightService,
                                      invisibleCharacterConfiguration: invisibleCharacterConfiguration)
        indentController = IndentController(stringView: stringView,
                                            lineManager: lineManager,
                                            languageMode: languageMode,
                                            indentStrategy: indentStrategy,
                                            indentFont: theme.font)
        lineMovementController = LineMovementController(lineManager: lineManager,
                                                        stringView: stringView,
                                                        lineControllerStorage: lineControllerStorage)
        super.init(frame: .zero)
        emphasisManager.highlightService = highlightService
        emphasisManager.onEmphasesChanged = { [weak self] in
            guard let self else {
                return
            }
            self.layoutManager.setNeedsLayout()
            self.setNeedsLayout()
        }
        emphasisManager.onSelectInDocument = { [weak self] range in
            self?.selection = range
        }
        bracketMatchingController.emphasisManager = emphasisManager
        diagnosticEmphasisController.emphasisManager = emphasisManager
        occurrenceHighlightController.emphasisManager = emphasisManager
        occurrenceHighlightController.tokenizer = tokenizer
        methodSeparatorController.onRowsChanged = { [weak self] rows in
            guard let self else { return }
            self.layoutManager.setMethodSeparatorRows(rows)
            self.layoutManager.setNeedsLayout()
            self.setNeedsLayout()
        }
        layoutManager.foldingController = foldingController
        layoutManager.focusModeController = focusModeController
        lineMovementController.foldingController = foldingController
        caretRectService.foldingController = foldingController
        customTokenizer.foldingController = foldingController
        selectionOverlayController = SelectionOverlayController(textInputView: self,
                                                                caretRectService: caretRectService,
                                                                selectionRectService: selectionRectService)
        selectionOverlayController.install()
        applyThemeToChildren()
        indentController.delegate = self
        lineControllerStorage.delegate = self
        gutterWidthService.gutterLeadingPadding = gutterLeadingPadding
        gutterWidthService.gutterTrailingPadding = gutterTrailingPadding
        gutterWidthService.gutterMinimumCharacterCount = gutterMinimumCharacterCount
        layoutManager.delegate = self
        layoutManager.textInputView = self
        layoutManager.metalCanvasView = metalCanvasView
        layoutManager.pageGuideView = pageGuideController.guideView
        metalCanvasView.onRenderingFailure = { [weak self] in
            self?.handleMetalRenderingFailure()
        }
        refreshMetalActivation()
        editMenuController.delegate = self
        setupContentSizeObserver()
        setupGutterWidthObserver()
        setupFoldingObserver()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    /// `NSTextView` accepts the first click on an inactive window so the editor focuses
    /// without requiring a second click. Default `NSView` behavior would only activate
    /// the window and drop the event.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        if canBecomeFirstResponder {
            delegate?.textInputViewWillBeginEditing(self)
        }
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            NSTextInputContext.current?.activate()
            delegate?.textInputViewDidBeginEditing(self)
        } else {
            // This is called in the case where:
            // 1. The view is the first responder.
            // 2. A view is presented modally on top of the editor.
            // 3. The modally presented view is dismissed.
            // 4. The responder chain attempts to make the text view first responder again but super.becomeFirstResponder() returns false.
            delegate?.textInputViewDidCancelBeginEditing(self)
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        NSTextInputContext.current?.deactivate()
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            delegate?.textInputViewDidEndEditing(self)
        }
        return didResignFirstResponder
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hasDeletedTextWithPendingLayoutSubviews = false
        // Metal consumes the page-guide geometry during the viewport layout below.
        layoutPageGuideIfNeeded()
        layoutManager.layoutIfNeeded()
        layoutManager.layoutLineSelectionIfNeeded()
        layoutMetalCanvasIfNeeded()
        updateSelectionOverlayPresentationHost()
        selectionOverlayController.updateLayout()
        // Defer selection notifications out of layout — hosts (SwiftUI) writing state
        // from these callbacks during AppKit layout abort with Update Constraints in Window.
        let shouldNotifyInputDelegate = notifyInputDelegateAboutSelectionChangeInLayoutSubviews
        let shouldNotifyDelegate = notifyDelegateAboutSelectionChangeInLayoutSubviews
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = false
        notifyDelegateAboutSelectionChangeInLayoutSubviews = false
        if shouldNotifyInputDelegate || shouldNotifyDelegate {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if shouldNotifyInputDelegate {
                    self.inputDelegate?.selectionWillChange(self)
                    self.inputDelegate?.selectionDidChange(self)
                }
                if shouldNotifyDelegate {
                    self.delegate?.textInputViewDidChangeSelection(self)
                }
            }
        }
    }

    @objc func copy(_ sender: Any?) {
        if multiSelectionController.hasMultipleSelections {
            UIPasteboard.general.string = joinedMultiSelectionText()
        } else if let selectedTextRange = selectedTextRange, let text = text(in: selectedTextRange) {
            UIPasteboard.general.string = text
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let string = UIPasteboard.general.string else {
            return
        }
        if multiSelectionController.hasMultipleSelections {
            let selections = multiSelectionController.selections
            let clipboardLines = string.components(separatedBy: lineEndings.symbol)
            if clipboardLines.count == selections.count {
                // Clipboard has exactly one line per caret — likely a block-copy. Distribute one
                // line per caret in top-to-bottom order rather than pasting the whole clipboard
                // at every site, so block-copy -> block-paste round-trips.
                insertDistributedTextAtAllSelections(clipboardLines)
            } else {
                insertTextAtAllSelections(prepareTextForInsertion(string))
            }
            return
        }
        if let selectedTextRange = selectedTextRange {
            inputDelegate?.selectionWillChange(self)
            let preparedText = prepareTextForInsertion(string)
            replace(selectedTextRange, withText: preparedText)
            inputDelegate?.selectionDidChange(self)
        }
    }

    @objc func cut(_ sender: Any?) {
        if multiSelectionController.hasMultipleSelections {
            UIPasteboard.general.string = joinedMultiSelectionText()
            insertTextAtAllSelections("")
        } else if let selectedTextRange = selectedTextRange, let text = text(in: selectedTextRange) {
            UIPasteboard.general.string = text
            replace(selectedTextRange, withText: "")
        }
    }

    /// The text of every selected range, in top-to-bottom document order, joined by the
    /// document's line-ending symbol — used by multi-caret/block copy and cut.
    private func joinedMultiSelectionText() -> String {
        multiSelectionController.selections
            .sorted { $0.location < $1.location }
            .map { text(in: $0) ?? "" }
            .joined(separator: lineEndings.symbol)
    }

    @objc override func selectAll(_ sender: Any?) {
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        selection = NSRange(location: 0, length: stringView.length)
    }

    /// When autocorrection is enabled and the user tap on a misspelled word, UITextInteraction will present
    /// a UIMenuController with suggestions for the correct spelling of the word. Selecting a suggestion will
    /// cause UITextInteraction to call the non-existing -replace(_:) function and pass an instance of the private
    /// UITextReplacement type as parameter. We can't make autocorrection work properly without using private API.
    @objc func replace(_ obj: NSObject) {
        if let replacementText = obj.value(forKey: "_repl" + "Ttnemeca".reversed() + "ext") as? String {
            if let indexedRange = obj.value(forKey: "_r" + "gna".reversed() + "e") as? IndexedRange {
                replace(indexedRange, withText: replacementText)
            }
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            if let selectedTextRange = selectedTextRange {
                return !selectedTextRange.isEmpty
            } else {
                return false
            }
        } else if action == #selector(cut(_:)) {
            guard delegate?.textInputViewIsEditable(self) ?? true else {
                return false
            }
            if let selectedTextRange = selectedTextRange {
                return isEditing && !selectedTextRange.isEmpty
            } else {
                return false
            }
        } else if action == #selector(paste(_:)) {
            let isEditable = delegate?.textInputViewIsEditable(self) ?? true
            return isEditing && isEditable && UIPasteboard.general.hasStrings
        } else if action == #selector(selectAll(_:)) {
            return true
        } else if action == #selector(replace(_:)) {
            return true
        } else if action == NSSelectorFromString("replaceTextInSelectedHighlightedRange") {
            if let selection = selection, let highlightedRange = highlightedRange(for: selection) {
                return delegate?.textInputView(self, canReplaceTextIn: highlightedRange) ?? false
            } else {
                return false
            }
        } else {
            return super.canPerformAction(action, withSender: sender)
        }
    }

    func linePosition(at location: Int) -> LinePosition? {
        lineManager.linePosition(at: location)
    }

    var isSyntaxTreeReady: Bool {
        languageMode.isSyntaxTreeReady
    }

    func cancelSyntaxParse() {
        languageMode.cancelParse()
    }

    // MARK: - Minimap content source

    /// Tree-sitter captures for an arbitrary byte range, or `[]` when there is no tree-sitter
    /// language mode. Used by the minimap to color its bars without going through
    /// `LineController`/Core Text.
    func minimapCaptures(inByteRange range: ByteRange) -> [TreeSitterCapture] {
        (languageMode as? TreeSitterInternalLanguageMode)?.captures(in: range) ?? []
    }

    /// Whether syntax colors can be produced for `range` right now.
    func minimapSyntaxAvailability(forUTF16Range range: NSRange) -> MinimapSyntaxAvailability {
        guard let treeSitterMode = languageMode as? TreeSitterInternalLanguageMode else {
            return .unavailable
        }
        guard treeSitterMode.isSyntaxTreeReady else {
            return .pending
        }
        return treeSitterMode.parsedRangeContains(range) ? .ready : .pending
    }

    /// Whether a line is currently hidden inside a collapsed fold. The minimap skips these so
    /// its rows line up with what the editor shows.
    func isLineHidden(_ lineID: DocumentLineNodeID) -> Bool {
        foldingController.isLineHidden(lineID)
    }

    func setState(_ state: TextViewState, addUndoAction: Bool = false) {
        if !inlayHints.isEmpty { inlayHints = [] }
        syntaxParseGeneration += 1
        let parseGeneration = syntaxParseGeneration
        syntaxParsePolicy = state.parsePolicy
        hasNotifiedSyntaxParse = false
        inFlightViewportParseRange = nil
        languageMode.cancelParse()
        if addUndoAction {
            let oldText = stringView.string
            let newText = state.stringView.string
            stringView = state.stringView
            theme = state.theme
            languageMode = state.languageMode
            lineControllerStorage.removeAllLineControllers()
            lineManager = state.lineManager
            lineManager.estimatedLineHeight = estimatedLineHeight
            layoutManager.languageMode = state.languageMode
            layoutManager.lineManager = state.lineManager
            contentSizeService.invalidateContentSize()
            gutterWidthService.invalidateLineNumberWidth()
            if newText != oldText {
                let newRange = NSRange(location: 0, length: newText.length)
                timedUndoManager.endUndoGrouping()
                timedUndoManager.beginUndoGrouping()
                addUndoOperation(replacing: newRange, withText: oldText as String)
                timedUndoManager.endUndoGrouping()
            }
        } else {
            stringView = state.stringView
            theme = state.theme
            languageMode = state.languageMode
            lineControllerStorage.removeAllLineControllers()
            lineManager = state.lineManager
            lineManager.estimatedLineHeight = estimatedLineHeight
            layoutManager.languageMode = state.languageMode
            layoutManager.lineManager = state.lineManager
            contentSizeService.invalidateContentSize()
            gutterWidthService.invalidateLineNumberWidth()
            timedUndoManager.removeAllActions()
        }
        if let oldSelectedRange = selection {
            inputDelegate?.selectionWillChange(self)
            selection = safeSelectionRange(from: oldSelectedRange)
            inputDelegate?.selectionDidChange(self)
        }
        if window != nil {
            performFullLayout()
        } else {
            hasPendingFullLayout = true
        }
        startDeferredParseIfNeeded(for: state, generation: parseGeneration)
    }

    func makeCapturedState() -> TextViewState {
        TextViewState(
            transferringStringView: stringView,
            lineManager: lineManager,
            languageMode: languageMode,
            theme: theme,
            parsePolicy: syntaxParsePolicy,
            detectedIndentStrategy: detectIndentStrategy(),
            detectedLineEndings: lineEndings,
            lengthOfLongestLine: lineManager.initialLongestLine?.data.totalLength
        )
    }

    func clearSelection() {
        selection = nil
    }

    func moveCaret(to point: CGPoint) {
        if let index = characterIndex(at: point) {
            selection = NSRange(location: index, length: 0)
        }
    }

    func characterIndex(at point: CGPoint) -> Int? {
        layoutManager.closestIndex(to: point)
    }

    func updateSelection(from anchor: Int, to index: Int) {
        let start = min(anchor, index)
        let end = max(anchor, index)
        inputDelegate?.selectionWillChange(self)
        selection = NSRange(location: start, length: end - start)
        inputDelegate?.selectionDidChange(self)
        // Host selection notify is deferred via `selection` setter.
    }

    func setLanguageMode(_ languageMode: LanguageMode, completion: ((Bool) -> Void)? = nil) {
        syntaxParseGeneration += 1
        let parseGeneration = syntaxParseGeneration
        self.languageMode.cancelParse()
        let internalLanguageMode = InternalLanguageModeFactory.internalLanguageMode(
            from: languageMode,
            stringView: stringView,
            lineManager: lineManager)
        self.languageMode = internalLanguageMode
        layoutManager.languageMode = internalLanguageMode
        internalLanguageMode.parse { [weak self] finished in
            guard let self, parseGeneration == self.syntaxParseGeneration else {
                completion?(false)
                return
            }
            if finished {
                self.invalidateLines()
                self.layoutManager.setNeedsLayout()
                self.setNeedsLayout()
                self.delegate?.textInputViewDidFinishSyntaxParse(self)
            }
            completion?(finished)
        }
    }

    private func startDeferredParseIfNeeded(for state: TextViewState, generation: Int) {
        guard !state.isSyntaxTreeReady else {
            return
        }
        switch state.parsePolicy {
        case .eager:
            break
        case .deferred:
            startFullParse(generation: generation, state: state)
        case .viewport:
            startViewportParse(generation: generation, state: state, notifyOnCompletion: true)
        }
    }

    /// Full reparse of the current string (``string`` setter, ``setLanguageMode``). Invalidates the
    /// existing tree first so highlighting does not run against a stale AST while the new parse is
    /// in flight. Reads from `stringView` (via `languageMode.parse(completion:)`) rather than
    /// taking a string argument — no implementation of `parse` has ever read a passed-in string.
    private func startFullParse() {
        guard languageMode is TreeSitterInternalLanguageMode else {
            return
        }
        syntaxParseGeneration += 1
        let generation = syntaxParseGeneration
        hasNotifiedSyntaxParse = false
        inFlightViewportParseRange = nil
        languageMode.invalidateSyntaxTree()
        if syntaxParsePolicy == .viewport {
            startViewportParse(generation: generation, state: nil, notifyOnCompletion: true)
        } else {
            startFullParse(generation: generation, state: nil)
        }
    }

    private func startFullParse(generation: Int, state: TextViewState?) {
        languageMode.parse { [weak self] finished in
            guard let self, generation == self.syntaxParseGeneration else {
                return
            }
            guard finished else {
                return
            }
            self.handleSyntaxParseFinished(state: state, notify: true)
        }
    }

    private func startViewportParse(generation: Int, state: TextViewState?, notifyOnCompletion: Bool) {
        guard let treeSitterMode = languageMode as? TreeSitterInternalLanguageMode else {
            return
        }
        let window = viewportUTF16Window()
        inFlightViewportParseRange = window
        treeSitterMode.parse(coveringUTF16Range: window) { [weak self] finished in
            guard let self, generation == self.syntaxParseGeneration else {
                return
            }
            self.inFlightViewportParseRange = nil
            guard finished else {
                return
            }
            let shouldNotify = notifyOnCompletion || !self.hasNotifiedSyntaxParse
            self.handleSyntaxParseFinished(state: state, notify: shouldNotify)
        }
    }

    /// Restart a deferred or viewport parse that `textDidChange` cancelled so the keystroke
    /// would not wait on `parseLock`. Incremental apply already ran if a tree existed.
    private func restartSyntaxParseAfterCancelledEdit() {
        guard !languageMode.isSyntaxTreeReady,
              languageMode is TreeSitterInternalLanguageMode else {
            return
        }
        syntaxParseGeneration += 1
        let generation = syntaxParseGeneration
        hasNotifiedSyntaxParse = false
        inFlightViewportParseRange = nil
        if syntaxParsePolicy == .viewport {
            startViewportParse(generation: generation, state: nil, notifyOnCompletion: true)
        } else {
            startFullParse(generation: generation, state: nil)
        }
    }

    /// Reparse the visible window when ``SyntaxParsePolicy/viewport`` is active and the current
    /// tree does not cover it. Called from the viewport setter, ``TextView`` layout, and after an
    /// in-flight parse finishes (so a scroll during that parse is not dropped).
    func ensureViewportSyntaxParse() {
        guard syntaxParsePolicy == .viewport,
              let treeSitterMode = languageMode as? TreeSitterInternalLanguageMode,
              treeSitterMode.isSyntaxTreeReady else {
            return
        }
        let visible = viewportUTF16Window(overscanScreens: 0)
        // An empty range at location 0 is contained by the leading window even when the
        // viewport has moved — only skip when we still have a real visible slice inside
        // the parsed range, or when we have not scrolled yet.
        if visible.length > 0, treeSitterMode.parsedRangeContains(visible) {
            return
        }
        if visible.length == 0, viewport.minY <= 0 {
            return
        }
        let window = viewportUTF16Window()
        if inFlightViewportParseRange == window {
            return
        }
        startViewportParse(generation: syntaxParseGeneration, state: nil, notifyOnCompletion: false)
    }

    private func viewportUTF16Window(
        overscanScreens: CGFloat = TreeSitterPerformanceConstants.viewportOverscanScreens
    ) -> NSRange {
        ViewportParseWindow.utf16Range(
            lineManager: lineManager,
            stringLength: stringView.length,
            viewport: viewport,
            overscanScreens: overscanScreens
        )
    }

    private func handleSyntaxParseFinished(state: TextViewState?, notify: Bool) {
        state?.applyDetectedIndentStrategy()
        applySyntaxColorRefreshAfterParse()
        layoutManager.setNeedsLayout()
        setNeedsLayout()
        // Every other invalidation path that can flip glyphs from stale to highlighted
        // (backing-scale change, marked-text/invisible-character toggles, …) schedules a
        // deferred flush so a layer-backed/SwiftUI host presents without depending on an
        // unrelated future layout pass. A parse landing is exactly that case for Metal's
        // hold-previous-glyphs policy (`MetalRenderer.upsertFragment`) — without this, a
        // host that never calls `layoutIfNeeded()` on its own can leave freshly-highlighted
        // colors unpresented indefinitely.
        scheduleDeferredLayoutIfNeeded()
        if notify {
            hasNotifiedSyntaxParse = true
            delegate?.textInputViewDidFinishSyntaxParse(self)
        }
        ensureViewportSyntaxParse()
    }

    func syntaxNode(at location: Int) -> SyntaxNode? {
        if let linePosition = lineManager.linePosition(at: location) {
            return languageMode.syntaxNode(at: linePosition)
        } else {
            return nil
        }
    }

    func isIndentation(at location: Int) -> Bool {
        guard let line = lineManager.line(containingCharacterAt: location) else {
            return false
        }
        let localLocation = location - line.location
        guard localLocation >= 0 else {
            return false
        }
        let indentLevel = languageMode.currentIndentLevel(of: line, using: indentStrategy)
        let indentString = indentStrategy.string(indentLevel: indentLevel)
        return localLocation <= indentString.utf16.count
    }

    func detectIndentStrategy() -> DetectedIndentStrategy {
        languageMode.detectIndentStrategy()
    }

    func textPreview(containing range: NSRange) -> TextPreview? {
        layoutManager.textPreview(containing: range)
    }

    func prepareLineForDisplay(atLocation location: Int) {
        layoutManager.prepareLineForDisplay(atLocation: location)
    }

    func lineAnchorY(at location: Int) -> CGFloat? {
        layoutManager.lineAnchorY(at: location)
    }

    func redisplayVisibleLines() {
        layoutManager.redisplayVisibleLines()
    }

    func refreshGutterChrome() {
        gutterWidthService.invalidateLineNumberWidth()
        layoutManager.refreshGutterChrome()
        setNeedsLayout()
    }

    var gutterDecorations: [GutterDecoration] {
        get { layoutManager.gutterDecorations }
        set { layoutManager.gutterDecorations = newValue }
    }

    var gutterDecorationHandler: ((Int) -> Void)? {
        get { layoutManager.gutterDecorationHandler }
        set { layoutManager.gutterDecorationHandler = newValue }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if hasPendingFullLayout && window != nil {
            hasPendingFullLayout = false
            performFullLayout()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        if result === self {
            timedUndoManager.endUndoGrouping()
        }
        return result
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            invalidateLines()
            layoutManager.setNeedsLayout()
        }
    }

    /// CoreText resolves a syntax-highlight token's `NSColor` to `CGColor` at typeset time
    /// (`LineTypesetter`), so a dynamic (appearance-adaptive) theme color is frozen against
    /// whatever the effective appearance was when a line was last typeset — typically off the
    /// main thread, well before any `draw(_:)` call. `traitCollectionDidChange` above is meant to
    /// catch this but never fires on macOS (`UITraitCollection.hasDifferentColorAppearance` is a
    /// UIKit-compat stub that always returns `false` here), so hook the real AppKit callback:
    /// force every line to re-typeset whenever the effective appearance actually changes,
    /// including when a caller forces one via `NSView.appearance` independent of the system
    /// setting.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateLines()
        layoutManager.invalidateMetalGlyphsForAppearanceChange()
        layoutManager.setNeedsLayout()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        if let keyCode = presses.first?.key?.keyCode, presses.count == 1 {
            if imeMarkedRange != nil {
                handleKeyPressDuringMultistageTextInput(keyCode: keyCode)
            }
        }
    }
}

// MARK: - Theming
private extension TextInputView {
    private func applyThemeToChildren() {
        gutterWidthService.font = theme.lineNumberFont
        lineManager.estimatedLineHeight = estimatedLineHeight
        indentController.indentFont = theme.font
        pageGuideController.font = theme.font
        pageGuideController.guideView.hairlineWidth = theme.pageGuideHairlineWidth
        pageGuideController.guideView.hairlineColor = theme.pageGuideHairlineColor.withAlphaComponent(pageGuideHairlineOpacity)
        pageGuideController.guideView.backgroundColor = theme.pageGuideBackgroundColor
        pageGuideController.guideView.shadingColor = theme.pageGuideBackgroundColor.withAlphaComponent(0.35)
        selectionHighlightColor = theme.selectionColor
        occurrenceHighlightController.theme = theme
        // Same instance skips `theme.didSet`, so copy the guide stroke here too.
        layoutManager.syncMethodSeparatorHairline(
            color: pageGuideController.guideView.hairlineColor,
            width: pageGuideController.guideView.hairlineWidth
        )
        layoutManager.theme = theme
    }
}

// MARK: - Navigation
private extension TextInputView {
    private func handleKeyPressDuringMultistageTextInput(keyCode: UIKeyboardHIDUsage) {
        // When editing multistage text input (that is, we have a marked text) we let the user unmark the text
        // by pressing the arrow keys or Escape. This isn't common in iOS apps but it's the default behavior
        // on macOS and I think that works quite well for plain text editors on iOS too.
        guard let imeMarkedRange = imeMarkedRange, let markedText = stringView.substring(in: imeMarkedRange) else {
            return
        }
        // We only unmark the text if the marked text contains specific characters only.
        // Some languages use multistage text input extensively and for those iOS presents a UI when
        // navigating with the arrow keys. We do not want to interfere with that interaction.
        let characterSet = CharacterSet(charactersIn: "`´^¨")
        guard markedText.rangeOfCharacter(from: characterSet.inverted) == nil else {
            return
        }
        switch keyCode {
        case .keyboardUpArrow:
            navigate(in: .up, offset: 1)
            unmarkText()
        case .keyboardRightArrow:
            navigate(in: .right, offset: 1)
            unmarkText()
        case .keyboardDownArrow:
            navigate(in: .down, offset: 1)
            unmarkText()
        case .keyboardLeftArrow:
            navigate(in: .left, offset: 1)
            unmarkText()
        case .keyboardEscape:
            unmarkText()
        }
    }

    private func navigate(in direction: UITextLayoutDirection, offset: Int) {
        if let selection = selection {
            if let location = lineMovementController.location(from: selection.location, in: direction, offset: offset) {
                self.selection = NSRange(location: location, length: 0)
            }
        }
    }
}

// MARK: - Layout
private extension TextInputView {
    private func layoutMetalCanvasIfNeeded() {
        guard isMetalRenderingActive else {
            return
        }
        // `LayoutManager.layoutLinesInViewport` presents inside its CATransaction when layout
        // ran. If this pass did not layout, still flush a pending dirty present (unhide, scale).
        metalCanvasView.presentIfDirty()
    }

    func refreshMetalActivation() {
        let defaults = UserDefaults.standard.object(forKey: MetalActivation.defaultsKey) as? Bool
        // Property-off (and the process-wide kill switch) never needs a Metal device check,
        // so default-off TextView init does not compile shaders.
        if !isMetalRenderingEnabled || defaults == false {
            applyMetalActivation(false)
            return
        }
        let resolved = MetalActivation.resolved(
            property: isMetalRenderingEnabled,
            deviceAvailable: MetalContext.shared.isAvailable,
            defaults: defaults
        )
        applyMetalActivation(resolved)
    }

    private func handleMetalRenderingFailure() {
        MetalContext.shared.markUnavailable()
        onMetalRenderingFailure?(MetalContext.shared.failureReason ?? "Metal rendering failed")
        applyMetalActivation(false)
    }

    private func applyMetalActivation(_ active: Bool) {
        // The renderer needs a Metal device + canvas; `setMetalRenderingActive` reports what took.
        let resolvedActive = layoutManager.setMetalRenderingActive(active) && active
        let didChange = isMetalRenderingActive != resolvedActive
        isMetalRenderingActive = resolvedActive
        metalCanvasView.isHidden = !resolvedActive
        if resolvedActive {
            metalCanvasView.setNeedsDisplay()
        }
        updateSelectionOverlayPresentationHost()
        if didChange {
            layoutManager.setNeedsLayout()
            setNeedsLayout()
        }
    }

    func updateSelectionOverlayPresentationHost() {
        selectionOverlayController.setPresentationHost(
            isMetalRenderingActive ? gutterParentView : nil,
            viewport: viewport
        )
        if isMetalRenderingActive {
            selectionOverlayController.placeAboveMetalCanvas()
        }
    }

    private func layoutPageGuideIfNeeded() {
        if showPageGuide {
            // The width extension is used to make the page guide look "attached" to the right hand side, even when the scroll view bouncing on the right side.
            let maxContentOffsetX = contentSizeService.contentWidth - viewport.width
            let widthExtension = max(ceil(viewport.minX - maxContentOffsetX), 0)
            let xPosition = gutterWidthService.gutterWidth + textContainerInset.left + pageGuideController.columnOffset
            let width = max(bounds.width - xPosition + widthExtension, 0)
            let orrigin = CGPoint(x: xPosition, y: viewport.minY)
            let pageGuideSize = CGSize(width: width, height: viewport.height)
            pageGuideController.guideView.frame = CGRect(origin: orrigin, size: pageGuideSize)
        }
    }

    private func performFullLayout() {
        invalidateLines()
        layoutManager.setNeedsLayout()
        setNeedsLayout()
    }

    private func invalidateLines() {
        for lineController in lineControllerStorage {
            lineController.lineFragmentHeightMultiplier = lineHeightMultiplier
            lineController.tabWidth = indentController.tabWidth
            lineController.kern = kern
            lineController.lineBreakMode = lineBreakMode
            lineController.invalidateSyntaxHighlighting()
        }
    }

    private func invalidateVisibleLineSyntaxHighlighting() {
        for lineController in lineControllerStorage {
            lineController.lineFragmentHeightMultiplier = lineHeightMultiplier
            lineController.tabWidth = indentController.tabWidth
            lineController.kern = kern
            lineController.lineBreakMode = lineBreakMode
        }
        layoutManager.invalidateSyntaxHighlightingOnVisibleLines()
    }

    /// Each `replaceText` bumps `contentGeneration` exactly once. Any other step means a change
    /// this set never saw, so fall back to a full minimap refresh.
    private func noteMinimapEdit(_ lineChangeSet: LineChangeSet) {
        let generation = stringView.contentGeneration
        guard let known = minimapKnownContentGeneration, generation == known &+ 1 else {
            invalidateAllMinimapRows()
            minimapKnownContentGeneration = generation
            return
        }
        minimapKnownContentGeneration = generation
        for line in lineChangeSet.editedLines {
            minimapDirtyLineIDs.insert(line.id)
        }
        for line in lineChangeSet.insertedLines {
            minimapDirtyLineIDs.insert(line.id)
        }
    }

    /// Rows are the post-parse tree's rows, so they're valid even after lines shifted.
    private func noteMinimapSyntaxRows(_ treeRows: [ClosedRange<Int>]?) {
        guard let treeRows else {
            invalidateAllMinimapRows()
            return
        }
        let lastRow = max(lineManager.lineCount - 1, 0)
        for range in treeRows {
            let lower = max(range.lowerBound, 0)
            let upper = min(range.upperBound, lastRow)
            guard lower <= upper else {
                continue
            }
            for row in lower ... upper {
                minimapDirtyLineIDs.insert(lineManager.line(atRow: row).id)
            }
        }
    }

    private func noteRowsNeedingSyntaxColor(_ lineChangeSet: LineChangeSet) {
        if !lineChangeSet.insertedLines.isEmpty || !lineChangeSet.removedLines.isEmpty {
            // Rows recorded before this edit, and separator rows below it, are now off by the delta.
            rowsShiftedSinceSyntaxParse = true
        }
        for line in lineChangeSet.editedLines {
            rowsEditedSinceSyntaxParse.insert(line.row)
        }
        for line in lineChangeSet.insertedLines {
            rowsEditedSinceSyntaxParse.insert(line.row)
        }
    }

    private func applySyntaxColorRefreshAfterParse() {
        var rows = rowsEditedSinceSyntaxParse
        let rowsShifted = rowsShiftedSinceSyntaxParse
        rowsEditedSinceSyntaxParse.removeAll()
        rowsShiftedSinceSyntaxParse = false
        let treeRows = (languageMode as? TreeSitterInternalLanguageMode)?.consumePendingSyntaxRows()
        noteMinimapSyntaxRows(treeRows)
        guard let treeRows, !rowsShifted else {
            invalidateVisibleLineSyntaxHighlighting()
            if !rowsShifted {
                layoutManager.invalidateSyntaxColors(onRows: rows, lineManager: lineManager)
            }
            methodSeparatorController.recompute()
            return
        }
        let lastRow = max(lineManager.lineCount - 1, 0)
        for range in treeRows {
            let lower = max(range.lowerBound, 0)
            let upper = min(range.upperBound, lastRow)
            guard lower <= upper else {
                continue
            }
            for row in lower ... upper {
                rows.insert(row)
            }
        }
        // A line still showing color-shifted guesses must get real colors from this tree.
        rows.formUnion(layoutManager.visibleStaleColorRows())
        layoutManager.invalidateSyntaxColors(onRows: rows, lineManager: lineManager)
        if let lower = rows.min(), let upper = rows.max() {
            methodSeparatorController.recompute(rowWindow: lower ... upper)
        }
    }

    private func setupContentSizeObserver() {
        contentSizeService.$isContentSizeInvalid.filter { $0 }.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.textInputViewDidInvalidateContentSize(self)
            }
        }.store(in: &cancellables)
    }

    private func setupGutterWidthObserver() {
        gutterWidthService.didUpdateGutterWidth.sink { [weak self] in
            guard let self else { return }
            // Gutter width is often published while layoutGutter() reads lineNumberWidth.
            // Defer invalidation so we do not setNeedsLayout / invalidateLines mid-pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setNeedsLayout()
                self.invalidateLines()
                self.layoutManager.setNeedsLayout()
                self.delegate?.textInputViewDidChangeGutterWidth(self)
            }
        }.store(in: &cancellables)
    }

    private func setupFoldingObserver() {
        foldingController.didChangeFolds.sink { [weak self] in
            self?.adjustSelectionForFoldingIfNeeded()
        }.store(in: &cancellables)
    }

    private func sanitizedSelection(_ range: NSRange?) -> NSRange? {
        guard let range, foldingController.isEnabled else {
            return range
        }
        return foldingController.adjustedSelection(range)
    }

    private func adjustSelectionForFoldingIfNeeded() {
        if multiSelectionController.hasMultipleSelections {
            let adjustedSelections = multiSelectionController.selections.map { foldingController.adjustedSelection($0) }
            if adjustedSelections != multiSelectionController.selections {
                applySelectedRanges(adjustedSelections, notifyDelegate: false)
            }
            return
        }
        guard let currentSelection = _selectedRange else {
            return
        }
        let adjustedSelection = foldingController.adjustedSelection(currentSelection)
        guard adjustedSelection != currentSelection else {
            return
        }
        selection = adjustedSelection
    }
}

extension TextInputView {
    /// Repaints syntax colours on lines touched by `utf16Ranges`, e.g. after semantic highlights changed.
    func refreshSyntaxColors(forUTF16Ranges utf16Ranges: [NSRange]) {
        var lineIDs = Set<DocumentLineNodeID>()
        for range in utf16Ranges where range.length > 0 || range.location < stringView.length {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: stringView.length))
            guard clamped.length > 0 else { continue }
            if let startLine = lineManager.line(containingCharacterAt: clamped.location) {
                lineIDs.insert(startLine.id)
            }
            let endLocation = max(clamped.upperBound - 1, clamped.location)
            if let endLine = lineManager.line(containingCharacterAt: endLocation) {
                lineIDs.insert(endLine.id)
            }
        }
        guard !lineIDs.isEmpty else { return }
        for lineID in lineIDs {
            lineControllerStorage[lineID]?.invalidateSyntaxHighlighting()
        }
        for lineID in lineIDs where layoutManager.currentlyVisibleLineIDs.contains(lineID) {
            layoutManager.redisplayLines(withIDs: [lineID])
        }
        layoutManager.setNeedsLayout()
        setNeedsLayout()
    }

    /// Repaints every line's syntax colours, e.g. after a theme change.
    func refreshSyntaxColors() {
        for lineController in lineControllerStorage {
            lineController.invalidateSyntaxHighlighting()
        }
        layoutManager.setNeedsLayout()
        setNeedsLayout()
    }
}

// MARK: - Multi Selection
extension TextInputView {
    func applySelectedRanges(_ ranges: [NSRange], primaryIndex: Int = 0, notifyDelegate: Bool = true) {
        let sanitized = ranges.compactMap { sanitizedSelection($0) }
        let normalized = MultiSelectionController.normalize(sanitized)
        isApplyingMultipleSelectionUpdate = true
        multiSelectionController.setSelections(normalized, primaryIndex: primaryIndex)
        let primary = multiSelectionController.primarySelection
        if primary != _selectedRange {
            // A nil primary (normalized to an empty set) legitimately clears the selection —
            // e.g. a block selection collapsing to nothing off the end of the document.
            _selectedRange = primary
        } else {
            layoutManager.selectedRange = _selectedRange
            layoutManager.setNeedsLayoutLineSelection()
            selectionOverlayController.selectionDidChange()
            setNeedsLayout()
        }
        isApplyingMultipleSelectionUpdate = false
        if !isApplyingSnippetSelection {
            invalidateSnippetSessionIfSelectionLeftStops(normalized)
        }
        updateFocusModeIfNeeded()
        if notifyDelegate {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.textInputViewDidChangeSelection(self)
            }
        }
    }

    /// Recomputes Focus Mode's focused ranges for the current selection set and redraws only if
    /// they actually changed — a caret move that stays within the same sentence/paragraph costs
    /// nothing beyond the resolver call.
    private func updateFocusModeIfNeeded() {
        guard focusModeController.updateFocusedRanges(for: selectedRanges) else {
            return
        }
        layoutManager.setNeedsLayout()
        setNeedsLayout()
    }

    func collapseMultiSelectionToPrimary() {
        guard multiSelectionController.hasMultipleSelections else {
            return
        }
        if let primary = multiSelectionController.primarySelection {
            applySelectedRanges([primary])
        }
    }

    /// Snapshots the current selection state into caret-set history before an additive multi-caret
    /// mutation, so ⌘U / `undoLastCaretChange()` can step back to it. Seeds the multi-selection
    /// controller with the current primary selection first when it isn't tracking anything yet, so
    /// the snapshot reflects the real pre-mutation state (one range) rather than an empty array.
    private func pushCaretHistory() {
        if multiSelectionController.selections.isEmpty, let primary = selection {
            multiSelectionController.setSelections([primary])
        }
        multiSelectionController.pushHistory()
    }

    func addSelection(at location: Int) {
        let range = sanitizedSelection(NSRange(location: location, length: 0)) ?? NSRange(location: location, length: 0)
        pushCaretHistory()
        guard multiSelectionController.addSelection(range) else {
            return
        }
        applySelectedRanges(multiSelectionController.selections, primaryIndex: multiSelectionController.primaryIndex)
    }

    func addSelectionsOnEachLine() {
        guard let currentSelection = selection, currentSelection.length > 0 else {
            return
        }
        guard let (startLine, endLine) = lineManager.startAndEndLine(in: currentSelection) else {
            return
        }
        var ranges: [NSRange] = []
        for row in startLine.index...endLine.index {
            let line = lineManager.line(atRow: row)
            ranges.append(NSRange(location: line.location, length: 0))
        }
        pushCaretHistory()
        applySelectedRanges(ranges)
    }

    func selectNextOccurrence() {
        if selection?.length == 0,
           let wordRange = SelectNextOccurrence.wordRange(at: selection?.location ?? 0, documentLength: stringView.length, tokenizer: tokenizer) {
            pushCaretHistory()
            applySelectedRanges([wordRange])
            return
        }
        let string = stringView.string
        guard let queryRange = selection, queryRange.length > 0,
              let query = text(in: queryRange), !query.isEmpty else {
            return
        }
        var ranges = selectedRanges.filter { $0.length == queryRange.length }
        if ranges.isEmpty {
            ranges = [queryRange]
        }
        let searchStart = ranges.map(\.upperBound).max() ?? queryRange.upperBound
        guard let next = SelectNextOccurrence.nextMatch(for: query,
                                                          length: queryRange.length,
                                                          in: string,
                                                          after: searchStart) else {
            return
        }
        guard !ranges.contains(where: { $0.location == next.location }) else {
            return
        }
        ranges.append(next)
        pushCaretHistory()
        applySelectedRanges(ranges)
    }

    /// Replaces the most recently added occurrence range (the one with the highest `location`,
    /// since `selectNextOccurrence()` always searches forward from the maximum upper bound) with
    /// the next match after it, rather than appending — lets you skip a match you don't want to
    /// rename without losing the ones already selected. No-op with fewer than two ranges.
    func skipCurrentOccurrence() {
        let string = stringView.string
        var ranges = selectedRanges
        guard ranges.count > 1, let mostRecent = ranges.max(by: { $0.location < $1.location }) else {
            return
        }
        let query = text(in: mostRecent) ?? ""
        guard !query.isEmpty else {
            return
        }
        let searchStart = mostRecent.upperBound
        guard let next = SelectNextOccurrence.nextMatch(for: query,
                                                          length: mostRecent.length,
                                                          in: string,
                                                          after: searchStart),
              !ranges.contains(where: { $0.location == next.location }) else {
            return
        }
        ranges.removeAll { $0.location == mostRecent.location && $0.length == mostRecent.length }
        ranges.append(next)
        pushCaretHistory()
        applySelectedRanges(ranges)
    }

    /// Selects every occurrence of the current query in the document. If the selection is empty,
    /// the word under the caret becomes the query first (matching `selectNextOccurrence()`).
    func selectAllOccurrences() {
        let string = stringView.string
        let queryRange: NSRange?
        if let selection, selection.length > 0 {
            queryRange = selection
        } else {
            queryRange = SelectNextOccurrence.wordRange(at: selection?.location ?? 0, documentLength: string.length, tokenizer: tokenizer)
        }
        guard let queryRange, let query = text(in: queryRange), !query.isEmpty else {
            return
        }
        let matches = SelectNextOccurrence.allMatches(for: query, in: string)
        guard !matches.isEmpty else {
            return
        }
        pushCaretHistory()
        applySelectedRanges(matches)
    }

    /// Adds a new caret one visual line above the topmost caret (`.up`) or below the bottommost
    /// caret (`.down`), reusing the same fragment-local vertical movement plain arrow keys use.
    /// No-op at a document edge, where movement can't advance past the existing caret.
    private func addCaret(in direction: UITextLayoutDirection) {
        let carets = selectedRanges.filter { $0.length == 0 }
        guard let source = direction == .up
            ? carets.min(by: { $0.location < $1.location })
            : carets.max(by: { $0.location < $1.location }) else {
            return
        }
        guard let newLocation = lineMovementController.location(from: source.location, in: direction, offset: 1),
              newLocation != source.location else {
            return
        }
        // addSelection(at:) pushes its own caret-history snapshot before mutating.
        addSelection(at: newLocation)
    }

    func addCaretAbove() {
        addCaret(in: .up)
    }

    func addCaretBelow() {
        addCaret(in: .down)
    }

    func undoLastCaretChange() {
        guard multiSelectionController.undoLastCaretChange() else {
            return
        }
        applySelectedRanges(multiSelectionController.selections, primaryIndex: multiSelectionController.primaryIndex)
    }

    /// Replaces, at every selection, the range beginning `relativeStartOffset` UTF-16 units from
    /// that selection's own start and extending `length` units — the same relative edit applied
    /// identically at every caret. Used by EditorIntelligence completion acceptance to apply a
    /// completion at every multi-cursor site once its replacement range relative to the primary
    /// caret is known. No-op when only one selection is active.
    func replaceAtAllSelections(relativeStartOffset: Int, length: Int, with text: String) {
        guard multiSelectionController.hasMultipleSelections else {
            return
        }
        let documentLength = stringView.length
        let editRanges = multiSelectionController.selections.map { selection -> NSRange in
            let location = min(max(selection.location + relativeStartOffset, 0), documentLength)
            let clampedLength = min(max(length, 0), documentLength - location)
            return NSRange(location: location, length: clampedLength)
        }
        insertTextAtAllSelections(text, at: editRanges)
    }

    func moveAllSelections(in direction: UITextLayoutDirection) {
        var newSelections: [NSRange] = []
        for range in selectedRanges {
            if range.length > 0 {
                newSelections.append(range)
                continue
            }
            guard let newLocation = lineMovementController.location(from: range.location, in: direction, offset: 1) else {
                newSelections.append(range)
                continue
            }
            newSelections.append(NSRange(location: newLocation, length: 0))
        }
        applySelectedRanges(MultiSelectionController.normalize(newSelections))
        if let primary = selection {
            selectionAnchor = primary.length == 0 ? primary.location : primary.upperBound
        }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.selectionDidChange(self)
    }
}

// MARK: - Block Selection
extension TextInputView {
    func beginBlockSelection(at point: CGPoint) {
        let row = layoutManager.lineIndex(forYPosition: point.y)
        blockSelectionController.begin(at: BlockSelectionAnchor(lineIndex: row, xPosition: point.x))
        applyMaterializedBlockSelection()
    }

    func extendBlockSelection(to point: CGPoint) {
        guard blockSelectionController.isActive else {
            beginBlockSelection(at: point)
            return
        }
        let row = layoutManager.lineIndex(forYPosition: point.y)
        blockSelectionController.extend(to: BlockSelectionAnchor(lineIndex: row, xPosition: point.x))
        applyMaterializedBlockSelection()
    }

    func endBlockSelection() {
        blockSelectionController.end()
    }

    /// Starts a block selection anchored at the current primary caret, if one isn't already
    /// active. Shared by keyboard block-extension (⌃⇧←/→/↑/↓) and Option+Shift-drag, both of
    /// which need to *extend* a block from wherever editing already is rather than requiring an
    /// existing block to already be in progress.
    func beginBlockSelectionAtCurrentCaretIfNeeded() {
        guard !blockSelectionController.isActive else {
            return
        }
        let origin = selection?.location ?? 0
        guard let line = lineManager.line(containingCharacterAt: origin) else {
            return
        }
        let originX = caretRectService.caretRect(at: origin, allowMovingCaretToNextLineFragment: true).minX
        blockSelectionController.begin(at: BlockSelectionAnchor(lineIndex: line.index, xPosition: originX))
    }

    /// Grows or shrinks the active block selection by one row/character via the keyboard
    /// (⌃⇧←/→/↑/↓). Starts a block at the current primary caret if one isn't already active.
    func extendBlockSelection(in direction: UITextLayoutDirection) {
        beginBlockSelectionAtCurrentCaretIfNeeded()
        guard let active = blockSelectionController.active else {
            return
        }
        var newRow = active.lineIndex
        var newX = active.xPosition
        switch direction {
        case .up:
            newRow = max(active.lineIndex - 1, 0)
        case .down:
            newRow = min(active.lineIndex + 1, max(lineManager.lineCount - 1, 0))
        case .left, .right:
            let currentIndex = layoutManager.closestIndex(toXPosition: newX, inLineAtRow: active.lineIndex)
            let newIndex = lineMovementController.location(from: currentIndex, in: direction, offset: 1) ?? currentIndex
            newX = caretRectService.caretRect(at: newIndex, allowMovingCaretToNextLineFragment: true).minX
        @unknown default:
            break
        }
        blockSelectionController.extend(to: BlockSelectionAnchor(lineIndex: newRow, xPosition: newX))
        applyMaterializedBlockSelection()
    }

    private func applyMaterializedBlockSelection() {
        let ranges = blockSelectionController.materializedRanges(lineCount: lineManager.lineCount) { [layoutManager] row, x in
            layoutManager.closestIndex(toXPosition: x, inLineAtRow: row)
        }
        guard !ranges.isEmpty else {
            return
        }
        isApplyingBlockSelectionUpdate = true
        applySelectedRanges(ranges)
        isApplyingBlockSelectionUpdate = false
    }
}

// MARK: - Floating Caret
extension TextInputView {
    func beginFloatingCursor(at point: CGPoint) {
        if floatingCaretView == nil, let position = closestPosition(to: point) {
            insertionPointColorBeforeFloatingBegan = insertionPointColor
            selectionOverlayController.isEnabled = false
            let caretRect = self.caretRect(for: position)
            let caretOrigin = CGPoint(x: point.x - caretRect.width / 2, y: point.y - caretRect.height / 2)
            let floatingCaretView = FloatingCaretView()
            floatingCaretView.backgroundColor = insertionPointColorBeforeFloatingBegan
            floatingCaretView.frame = CGRect(origin: caretOrigin, size: caretRect.size)
            addSubview(floatingCaretView)
            self.floatingCaretView = floatingCaretView
            delegate?.textInputViewDidBeginFloatingCursor(self)
        }
    }

    func updateFloatingCursor(at point: CGPoint) {
        if let floatingCaretView = floatingCaretView {
            let caretSize = floatingCaretView.frame.size
            let caretOrigin = CGPoint(x: point.x - caretSize.width / 2, y: point.y - caretSize.height / 2)
            floatingCaretView.frame = CGRect(origin: caretOrigin, size: caretSize)
        }
    }

    func endFloatingCursor() {
        if isEditing {
            selectionOverlayController.isEnabled = true
            selectionOverlayController.updateLayout()
        }
        floatingCaretView?.removeFromSuperview()
        floatingCaretView = nil
        delegate?.textInputViewDidEndFloatingCursor(self)
    }
}

// MARK: - Rects
extension TextInputView {
    func caretRect(for position: UITextPosition) -> CGRect {
        guard let indexedPosition = position as? IndexedPosition else {
            fatalError("Expected position to be of type \(IndexedPosition.self)")
        }
        return caretRectService.caretRect(at: indexedPosition.index, allowMovingCaretToNextLineFragment: true)
    }

    func caretRect(at location: Int) -> CGRect {
        caretRectService.caretRect(at: location, allowMovingCaretToNextLineFragment: true)
    }

    func firstRect(for range: UITextRange) -> CGRect {
        guard let indexedRange = range as? IndexedRange else {
            fatalError("Expected range to be of type \(IndexedRange.self)")
        }
        return layoutManager.firstRect(for: indexedRange.range)
    }
}

// MARK: - Editing
extension TextInputView {
    func insertText(_ text: String) {
        let preparedText = prepareTextForInsertion(text)
        let traceEnabled = EditorPerformanceTrace.shared.isEnabled
        let insertStart = traceEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        KeystrokeBudgetMetrics.observerPending = traceEnabled
        isRestoringPreviouslyDeletedText = hasDeletedTextWithPendingLayoutSubviews
        hasDeletedTextWithPendingLayoutSubviews = false
        defer {
            isRestoringPreviouslyDeletedText = false
            if imeMarkedRange == nil {
                if traceEnabled {
                    let seconds = Double(DispatchTime.now().uptimeNanoseconds &- insertStart) / 1_000_000_000
                    EditorPerformanceTrace.shared.record(.untilTypingObserver, seconds: seconds)
                    let nextDrawableCount = KeystrokeBudgetMetrics.consumeNextDrawableBeforeObserverCount()
                    EditorPerformanceTrace.shared.recordCount(.metalWaits, count: 0)
                    let syncLines = EditorPerformanceTrace.shared.counts(for: .syncHighlightLines).reduce(0, +)
                    EditorPerformanceTrace.shared.recordCount(.syncHighlightLines, count: syncLines)
                    EditorPerformanceTrace.shared.recordCount(.metalPresents, count: nextDrawableCount)
                }
                KeystrokeBudgetMetrics.observerPending = false
                onTypingEvent?(.inserted(text))
            }
        }
        if multiSelectionController.hasMultipleSelections {
            if LineEnding(symbol: text) != nil {
                insertLineBreakAtAllSelections()
            } else {
                insertTextAtAllSelections(preparedText)
            }
            return
        }
        // If there is no marked range or selected range then we fallback to appending text to the end of our string.
        let replacementRange = imeMarkedRange ?? selection ?? NSRange(location: stringView.length, length: 0)
        guard shouldChangeText(in: replacementRange, replacementText: preparedText) else {
            isRestoringPreviouslyDeletedText = false
            return
        }
        // If we're inserting text then we can't have a marked range. However, UITextInput doesn't always clear the marked range
        // before calling -insertText(_:), so we do it manually. This issue can be tested by entering a backtick (`) in an empty
        // document, then pressing any arrow key (up, right, down or left) followed by the return key.
        // The backtick will remain marked unless we manually clear the marked range.
        imeMarkedRange = nil
        if LineEnding(symbol: text) != nil {
            indentController.insertLineBreak(in: replacementRange, using: lineEndings)
            setNeedsLayout()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.textInputViewDidChangeSelection(self)
            }
        } else {
            replaceText(in: replacementRange, with: preparedText)
            setNeedsLayout()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.textInputViewDidChangeSelection(self)
            }
        }
    }

    func deleteBackward() {
        didCallDeleteBackward = true
        defer {
            onTypingEvent?(.deletedBackward)
        }
        if multiSelectionController.hasMultipleSelections {
            deleteBackwardAtAllSelections()
            return
        }
        guard let currentSelection = imeMarkedRange ?? selection else {
            return
        }
        let deleteSelection: NSRange
        if currentSelection.length == 0 {
            guard currentSelection.location > 0 else {
                return
            }
            let characterRange = stringView.rangeOfComposedCharacterSequence(at: currentSelection.location - 1)
            deleteSelection = NSRange(location: characterRange.location, length: currentSelection.location - characterRange.location)
        } else {
            deleteSelection = currentSelection
        }
        let deleteRange = rangeForDeletingText(in: deleteSelection)
        // If we're deleting everything in the marked range then we clear the marked range. UITextInput doesn't do that for us.
        // Can be tested by entering a backtick (`) in an empty document and deleting it.
        if deleteRange == imeMarkedRange {
            imeMarkedRange = nil
        }
        guard shouldChangeText(in: deleteRange, replacementText: "") else {
            return
        }
        // Set a flag indicating that we have deleted text. This is reset in -layoutSubviews() but if this has not been reset before insertText() is called, then UIKit deleted characters prior to inserting combined characters. This happens when UIKit turns Korean characters into a single character. E.g. when typing ㅇ followed by ㅓ UIKit will perform the following operations:
        // 1. Delete ㅇ.
        // 2. Delete the character before ㅇ. I'm unsure why this is needed.
        // 3. Insert the character that was previously before ㅇ.
        // 4. Insert the ㅇ and ㅓ but combined into the single character delete ㅇ and then insert 어.
        // We can detect this case in insertText() by checking if this variable is true.
        hasDeletedTextWithPendingLayoutSubviews = true
        // Disable notifying delegate in layout subviews to prevent sending the selected range with length > 0 when deleting text. This aligns with the behavior of UITextView and was introduced to resolve issue #158: https://github.com/simonbs/Runestone/issues/158
        notifyDelegateAboutSelectionChangeInLayoutSubviews = false
        // Disable notifying input delegate in layout subviews to prevent issues when entering Korean text. This workaround is inspired by a dialog with Alexander Black (@lextar), developer of Textastic.
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = false
        // Just before calling deleteBackward(), UIKit will set the selected range to a range of length 1, if the selected range has a length of 0.
        // In that case we want to undo to a selected range of length 0, so we construct our range here and pass it all the way to the undo operation.
        let selectedRangeAfterUndo: NSRange
        if deleteRange.length == 1 {
            selectedRangeAfterUndo = NSRange(location: deleteSelection.upperBound, length: 0)
        } else {
            selectedRangeAfterUndo = deleteSelection
        }
        let isDeletingMultipleCharacters = deleteSelection.length > 1
        if isDeletingMultipleCharacters {
            timedUndoManager.endUndoGrouping()
            timedUndoManager.beginUndoGrouping()
        }
        replaceText(in: deleteRange, with: "", selectedRangeAfterUndo: selectedRangeAfterUndo)
        // Sending selection changed without calling the input delegate directly. This ensures that both inputting Korean letters and deleting entire words with Option+Backspace works properly.
        sendSelectionChangedToTextSelectionView()
        if isDeletingMultipleCharacters {
            timedUndoManager.endUndoGrouping()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.textInputViewDidChangeSelection(self)
        }
    }

    func deleteForward() {
        if multiSelectionController.hasMultipleSelections {
            deleteForwardAtAllSelections()
            return
        }
        guard let currentSelection = imeMarkedRange ?? selection else {
            return
        }
        let range: NSRange
        if currentSelection.length == 0 {
            guard currentSelection.location < stringView.length else {
                return
            }
            range = stringView.rangeOfComposedCharacterSequence(at: currentSelection.location)
        } else {
            range = currentSelection
        }
        replace(IndexedRange(range), withText: "")
    }

    func deleteWord(backward: Bool) {
        guard let currentRange = selection else {
            return
        }
        let position = IndexedPosition(index: backward ? currentRange.location : currentRange.upperBound)
        let direction: UITextDirection = backward ? .backward : .forward
        guard let boundary = tokenizer.position(from: position, toBoundary: .word, inDirection: direction) as? IndexedPosition else {
            return
        }
        let deleteRange: NSRange
        if backward {
            deleteRange = NSRange(location: boundary.index, length: currentRange.upperBound - boundary.index)
        } else {
            deleteRange = NSRange(location: currentRange.location, length: boundary.index - currentRange.location)
        }
        guard deleteRange.length > 0 else {
            return
        }
        selection = deleteRange
        deleteBackward()
    }

    func replace(_ range: UITextRange, withText text: String) {
        let preparedText = prepareTextForInsertion(text)
        if let indexedRange = range as? IndexedRange, shouldChangeText(in: indexedRange.range.nonNegativeLength, replacementText: preparedText) {
            replaceText(in: indexedRange.range.nonNegativeLength, with: preparedText)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.textInputViewDidChangeSelection(self)
            }
        }
    }

    func replaceText(in batchReplaceSet: BatchReplaceSet) {
        guard !batchReplaceSet.replacements.isEmpty else {
            return
        }
        var oldLinePosition: LinePosition?
        if let oldSelectedRange = selection {
            oldLinePosition = lineManager.linePosition(at: oldSelectedRange.location)
        }
        let textEditHelper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: lineEndings)
        let application = textEditHelper.apply(batchReplaceSet)
        if !inlayHints.isEmpty { inlayHints = [] }
        registerBatchUndo(inverseReplacements: application.inverseReplacements)
        invalidateLines()
        layoutManager.setNeedsLayout()
        setNeedsLayout()
        contentSizeService.invalidateContentSize()
        gutterWidthService.invalidateLineNumberWidth()
        delegate?.textInputViewDidChange(self)
        if let oldLinePosition = oldLinePosition {
            // By restoring the selected range using the old line position we can better preserve the old selected language.
            moveCaret(to: oldLinePosition)
        }
    }

    func text(in range: UITextRange) -> String? {
        if let indexedRange = range as? IndexedRange {
            return text(in: indexedRange.range.nonNegativeLength)
        } else {
            return nil
        }
    }

    func text(in range: NSRange) -> String? {
        stringView.substring(in: range)
    }

    /// `inverseReplacements` is a delta list (range + old text, sized to what was edited) rather
    /// than a full-document snapshot — undoing replays it through `replaceText(in:)`, which
    /// computes its own inverse in turn, so redo/undo/redo... never holds more than one edit's
    /// worth of text per step, regardless of document size. See PERFORMANCE_AUDIT.md Phase 2 #7.
    private func registerBatchUndo(inverseReplacements: [BatchReplaceSet.Replacement]) {
        let isNestedInUndoOrRedo = timedUndoManager.isUndoing || timedUndoManager.isRedoing
        if !isNestedInUndoOrRedo {
            timedUndoManager.endUndoGrouping()
            timedUndoManager.beginUndoGrouping()
            timedUndoManager.setActionName(L10n.Undo.ActionName.replaceAll)
        }
        timedUndoManager.registerUndo(withTarget: self) { textInputView in
            textInputView.replaceText(in: BatchReplaceSet(replacements: inverseReplacements))
        }
        timedUndoManager.notePayloadBytes(Self.undoPayloadBytes(for: inverseReplacements))
        if !isNestedInUndoOrRedo {
            timedUndoManager.endUndoGrouping()
        }
    }

    private func setStringWithUndoAction(_ newString: NSString, inverseReplacements: [BatchReplaceSet.Replacement]) {
        guard newString != string else {
            return
        }
        // When this runs as the body of an undo/redo invocation (i.e. `registerUndo`'s closure,
        // below, calling back into this method), `UndoManager` already has its own implicit group
        // open around the invocation, to collect whatever `registerUndo` call happens inside it as
        // the opposite-direction action. Unconditionally closing/reopening a group here — as this
        // method used to, pre-existing bug independent of the delta-vs-snapshot change above —
        // ends that implicit group early; when the manager tries to finalize it after this method
        // returns, its bookkeeping is already inconsistent and it raises
        // "endUndoGrouping called with no matching begin". Only manage grouping explicitly for a
        // top-level (non-nested) call; a nested call relies on the manager's own grouping.
        let isNestedInUndoOrRedo = timedUndoManager.isUndoing || timedUndoManager.isRedoing
        if !isNestedInUndoOrRedo {
            timedUndoManager.endUndoGrouping()
        }
        let oldSelectedRange = selection
        preserveUndoStackWhenSettingString = true
        string = newString
        preserveUndoStackWhenSettingString = false
        if !isNestedInUndoOrRedo {
            timedUndoManager.beginUndoGrouping()
            timedUndoManager.setActionName(L10n.Undo.ActionName.replaceAll)
        }
        timedUndoManager.registerUndo(withTarget: self) { textInputView in
            textInputView.replaceText(in: BatchReplaceSet(replacements: inverseReplacements))
        }
        timedUndoManager.notePayloadBytes(Self.undoPayloadBytes(for: inverseReplacements))
        if !isNestedInUndoOrRedo {
            timedUndoManager.endUndoGrouping()
        }
        delegate?.textInputViewDidChange(self)
        if let oldSelectedRange = oldSelectedRange {
            selection = safeSelectionRange(from: oldSelectedRange)
        }
    }

    private func rangeForDeletingText(in range: NSRange) -> NSRange {
        var resultingRange = range
        if range.length == 1, let indentRange = indentController.indentRangeInFrontOfLocation(range.upperBound) {
            resultingRange = indentRange
        } else {
            resultingRange = stringView.rangeOfComposedCharacterSequences(for: range)
        }
        // If deleting the leading component of a character pair we may also expand the range to delete the trailing component.
        if characterPairTrailingComponentDeletionMode == .immediatelyFollowingLeadingComponent
            && maximumLeadingCharacterPairComponentLength > 0
            && resultingRange.length <= maximumLeadingCharacterPairComponentLength {
            let stringToDelete = stringView.substring(in: resultingRange)
            if let characterPair = characterPairs.first(where: { $0.leading == stringToDelete }) {
                let trailingComponentLength = characterPair.trailing.utf16.count
                let trailingComponentRange = NSRange(location: resultingRange.upperBound, length: trailingComponentLength)
                if stringView.substring(in: trailingComponentRange) == characterPair.trailing {
                    let deleteRange = trailingComponentRange.upperBound - resultingRange.lowerBound
                    resultingRange = NSRange(location: resultingRange.lowerBound, length: deleteRange)
                }
            }
        }
        return resultingRange
    }

    func replaceText(in range: NSRange,
                             with newString: String,
                             selectedRangeAfterUndo: NSRange? = nil,
                             selectedRangesAfterUndo: [NSRange]? = nil,
                             primaryIndexAfterUndo: Int = 0,
                             undoActionName: String = L10n.Undo.ActionName.typing,
                             updateSelection: Bool = true) {
        let nsNewString = newString as NSString
        lastReplaceEditRange = range
        lastReplaceNewString = newString
        let currentText = text(in: range) ?? ""
        let newRange = NSRange(location: range.location, length: nsNewString.length)
        multiSelectionController.clearHistory()
        EditorPerformanceTrace.shared.measure(.undo) {
            addUndoOperation(replacing: newRange,
                             withText: currentText,
                             selectedRangeAfterUndo: selectedRangeAfterUndo,
                             selectedRangesAfterUndo: selectedRangesAfterUndo,
                             primaryIndexAfterUndo: primaryIndexAfterUndo,
                             actionName: undoActionName)
        }
        EditorPerformanceTrace.shared.measure(.caret) {
            if updateSelection {
                _selectedRange = NSRange(location: newRange.upperBound, length: 0)
                if !isApplyingMultipleSelectionUpdate {
                    multiSelectionController.setSelections(_selectedRange.map { [$0] } ?? [])
                }
            }
        }
        let textEditHelper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: lineEndings)
        let textEditResult = EditorPerformanceTrace.shared.measure(.textMutation) {
            textEditHelper.replaceText(in: range, with: newString)
        }
        if !inlayHints.isEmpty {
            inlayHints = InlayHintIndex.applyingEdit(to: inlayHints, range: range, replacementLength: nsNewString.length)
        }
        let textChange = textEditResult.textChange
        let lineChangeSet = textEditResult.lineChangeSet
        semanticHighlights.applyEdit(range: range, newLength: nsNewString.length)
        let languageModeLineChangeSet = EditorPerformanceTrace.shared.measure(.incrementalParse) {
            languageMode.textDidChange(textChange)
        }
        lineChangeSet.union(with: languageModeLineChangeSet)
        // Always recorded: a color-shifted keystroke skips tree-sitter and relies on the
        // post-parse recolor, and the tree diff does not report text changed inside a leaf.
        noteRowsNeedingSyntaxColor(lineChangeSet)
        noteMinimapEdit(lineChangeSet)
        EditorPerformanceTrace.shared.measure(.visibleLayout) {
            applyLineChangesToLayoutManager(lineChangeSet)
        }
        EditorPerformanceTrace.shared.measure(.incrementalParse) {
            restartSyntaxParseAfterCancelledEdit()
        }
        let updatedTextEditResult = TextEditResult(textChange: textChange, lineChangeSet: lineChangeSet)
        let change = TextContentChange(
            range: range,
            replacementText: newString,
            start: TextLocation(textChange.startLinePosition),
            oldEnd: TextLocation(textChange.oldEndLinePosition)
        )
        delegate?.textInputView(self, didChangeContent: change)
        if var session = snippetSession {
            if session.applyEdit(range: range, replacementLength: nsNewString.length) {
                snippetSession = session
            } else {
                snippetSession = nil
            }
        }
        delegate?.textInputViewDidChange(self)
        if updatedTextEditResult.didAddOrRemoveLines {
            delegate?.textInputViewDidInvalidateContentSize(self)
        }
    }

    private func applyLineChangesToLayoutManager(_ lineChangeSet: LineChangeSet) {
        let didAddOrRemoveLines = !lineChangeSet.insertedLines.isEmpty || !lineChangeSet.removedLines.isEmpty
        PenumbraSignposts.event(
            didAddOrRemoveLines
                ? "TextInputView.lineStructureChanged"
                : "TextInputView.lineContentChanged"
        )
        if didAddOrRemoveLines {
            contentSizeService.invalidateContentSize()
            for removedLine in lineChangeSet.removedLines {
                lineControllerStorage.removeLineController(withID: removedLine.id)
                contentSizeService.removeLine(withID: removedLine.id)
            }
        }
        let editedLineIDs = Set(lineChangeSet.editedLines.map(\.id))
        let colorShift: (utf16RangeInLine: NSRange, text: String)?
        if editedLineIDs.count == 1,
           lineChangeSet.insertedLines.isEmpty,
           lineChangeSet.removedLines.isEmpty,
           let line = lineChangeSet.editedLines.first {
            let lineRange = NSRange(location: line.location, length: line.data.length)
            if lastReplaceEditRange.location >= lineRange.location,
               lastReplaceEditRange.upperBound <= lineRange.upperBound + (lastReplaceNewString as NSString).length {
                let localRange = NSRange(
                    location: lastReplaceEditRange.location - lineRange.location,
                    length: lastReplaceEditRange.length
                )
                colorShift = (localRange, lastReplaceNewString)
            } else {
                colorShift = nil
            }
        } else {
            colorShift = nil
        }
        let contentSizeBeforeEdit = contentSize
        let heightChanged = layoutManager.redisplayLines(withIDs: editedLineIDs, colorShift: colorShift)
        if contentSize != contentSizeBeforeEdit {
            delegate?.textInputViewDidInvalidateContentSize(self)
        }
        if !didAddOrRemoveLines {
            selectionOverlayController.updateLayout()
        }
        if didAddOrRemoveLines {
            gutterWidthService.invalidateLineNumberWidth()
            layoutManager.relayoutVisibleFragmentsAfterLineStructureChange()
            selectionOverlayController.updateLayout()
        }
        if foldingController.isEnabled {
            let previousLineCount = lineManager.lineCount - lineChangeSet.insertedLines.count + lineChangeSet.removedLines.count
            let spliceRow = lineChangeSet.spliceRow ?? 0
            let delta = lineChangeSet.insertedLines.count - lineChangeSet.removedLines.count
            foldingController.foldProvider.invalidateForEdit(
                changedRows: lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount),
                lineCount: lineManager.lineCount,
                previousLineCount: previousLineCount,
                spliceRow: spliceRow
            )
            foldingController.applyLineDelta(at: spliceRow, delta: delta)
            if let rows = lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount) {
                foldingController.setNeedsRecompute(rows: rows)
            } else {
                foldingController.setNeedsRecompute()
            }
        }
        // One existing line whose height did not change is already typeset and on the canvas.
        // Walking the rest of the viewport here is what made a 360-line file hitch on every character.
        let stableSingleLine = !didAddOrRemoveLines && editedLineIDs.count <= 1 && !heightChanged
        if stableSingleLine {
            layoutManager.clearRecentlyEditedLineIDs()
            return
        }
        layoutManager.setNeedsLayoutLineSelection()
        layoutManager.setNeedsLayout()
        setNeedsLayout()
        scheduleDeferredLayoutIfNeeded()
    }

    func shouldChangeText(in range: NSRange, replacementText text: String) -> Bool {
        delegate?.textInputView(self, shouldChangeTextIn: range, replacementText: text) ?? true
    }

    private func addUndoOperation(replacing range: NSRange,
                                  withText text: String,
                                  selectedRangeAfterUndo: NSRange? = nil,
                                  selectedRangesAfterUndo: [NSRange]? = nil,
                                  primaryIndexAfterUndo: Int = 0,
                                  actionName: String = L10n.Undo.ActionName.typing) {
        let oldSelectedRange = selectedRangeAfterUndo ?? selection
        timedUndoManager.beginUndoGrouping()
        timedUndoManager.setActionName(actionName)
        timedUndoManager.registerUndo(withTarget: self) { textInputView in
            textInputView.imeMarkedRange = nil
            textInputView.inputDelegate?.selectionWillChange(textInputView)
            textInputView.replaceText(in: range, with: text)
            // A multi-range restore target (captured once, before a whole batch of edits) takes
            // priority over the single-range one: every edit within a multi-caret/block batch
            // registers its own undo step with the *same* pre-batch set, so however many of them
            // the grouped undo replays, the caret set that lands is that same full pre-batch set —
            // not just the primary caret, which is what a single `NSRange` restore would collapse to.
            if let selectedRangesAfterUndo, !selectedRangesAfterUndo.isEmpty {
                textInputView.applySelectedRanges(selectedRangesAfterUndo, primaryIndex: primaryIndexAfterUndo, notifyDelegate: false)
            } else {
                textInputView.selection = oldSelectedRange
            }
            textInputView.inputDelegate?.selectionDidChange(textInputView)
        }
        timedUndoManager.notePayloadBytes((text as NSString).length * 2)
    }

    private static func undoPayloadBytes(for replacements: [BatchReplaceSet.Replacement]) -> Int {
        replacements.reduce(0) { $0 + ($1.text as NSString).length * 2 }
    }

    private func prepareTextForInsertion(_ text: String) -> String {
        // Ensure all line endings match our preferred line endings.
        var preparedText = text
        let lineEndingsToReplace: [LineEnding] = [.crlf, .cr, .lf].filter { $0 != lineEndings }
        for lineEnding in lineEndingsToReplace {
            preparedText = preparedText.replacing(lineEnding.symbol, with: lineEndings.symbol)
        }
        return preparedText
    }

    /// Replaces `explicitRanges` (defaulting to the current selections) with `text` at every
    /// site, in one undo group. `explicitRanges`, when given, is purely which ranges get edited —
    /// undo still restores the real pre-edit *selections*, not those ranges, since a caller like
    /// `replaceAtAllSelections(relativeStartOffset:length:with:)` derives them from the selections
    /// rather than using the selections themselves as the edit ranges.
    func insertTextAtAllSelections(_ text: String, at explicitRanges: [NSRange]? = nil) {
        let originalSelections = multiSelectionController.selections
        let editRanges = (explicitRanges ?? originalSelections).sorted { $0.location > $1.location }
        guard !editRanges.isEmpty else {
            return
        }
        guard editRanges.allSatisfy({ shouldChangeText(in: $0, replacementText: text) }) else {
            return
        }
        imeMarkedRange = nil
        timedUndoManager.beginIsolatedUndoGrouping()
        let primaryIndex = multiSelectionController.primaryIndex
        var newSelections: [NSRange] = []
        for range in editRanges {
            replaceText(in: range, with: text, selectedRangesAfterUndo: originalSelections, primaryIndexAfterUndo: primaryIndex, updateSelection: false)
            newSelections.append(NSRange(location: range.location + text.utf16.count, length: 0))
        }
        timedUndoManager.endUndoGrouping()
        applySelectedRanges(newSelections.sorted { $0.location < $1.location }, notifyDelegate: false)
        setNeedsLayout()
        delegate?.textInputViewDidChange(self)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.textInputViewDidChangeSelection(self)
        }
    }

    /// Inserts a language-aware line break (indentation and all — the same as the single-caret
    /// path) at every selection. `IndentController` reports the resulting per-site caret through
    /// its `shouldSelect` delegate callback (or implicitly via `replaceText`'s own default when it
    /// doesn't fire one), which lands in `_selectedRange` after each call — read that back rather
    /// than letting each iteration's single-range assignment stand, since only the very last one
    /// would otherwise survive and every other caret would be lost.
    private func insertLineBreakAtAllSelections() {
        let selections = multiSelectionController.selections.sorted { $0.location > $1.location }
        guard !selections.isEmpty else {
            return
        }
        guard selections.allSatisfy({ shouldChangeText(in: $0, replacementText: lineEndings.symbol) }) else {
            return
        }
        imeMarkedRange = nil
        timedUndoManager.beginIsolatedUndoGrouping()
        pendingMultiSelectionUndoRestore = (selections, multiSelectionController.primaryIndex)
        var newSelections: [NSRange] = []
        for selection in selections {
            indentController.insertLineBreak(in: selection, using: lineEndings)
            newSelections.append(_selectedRange ?? NSRange(location: selection.location, length: 0))
        }
        pendingMultiSelectionUndoRestore = nil
        timedUndoManager.endUndoGrouping()
        applySelectedRanges(newSelections.sorted { $0.location < $1.location }, notifyDelegate: false)
        setNeedsLayout()
        delegate?.textInputViewDidChange(self)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.textInputViewDidChangeSelection(self)
        }
    }

    /// Pairs `lines[i]` with the i-th selection in ascending document order (top row gets the
    /// first line) and replaces each selection with its paired line — used for block-paste after
    /// a block-copy produced one line per caret, so distribution stays row-for-row rather than
    /// pasting the same text at every site.
    private func insertDistributedTextAtAllSelections(_ lines: [String]) {
        let ascendingSelections = multiSelectionController.selections.sorted { $0.location < $1.location }
        guard ascendingSelections.count == lines.count else {
            return
        }
        let pairs = zip(ascendingSelections, lines).sorted { $0.0.location > $1.0.location }
        guard pairs.allSatisfy({ shouldChangeText(in: $0.0, replacementText: $0.1) }) else {
            return
        }
        imeMarkedRange = nil
        timedUndoManager.beginIsolatedUndoGrouping()
        let restoreRanges = multiSelectionController.selections
        let primaryIndex = multiSelectionController.primaryIndex
        var newSelections: [NSRange] = []
        for (selection, text) in pairs {
            replaceText(in: selection,
                       with: text,
                       selectedRangesAfterUndo: restoreRanges,
                       primaryIndexAfterUndo: primaryIndex,
                       updateSelection: false)
            newSelections.append(NSRange(location: selection.location + (text as NSString).length, length: 0))
        }
        timedUndoManager.endUndoGrouping()
        applySelectedRanges(newSelections.sorted { $0.location < $1.location }, notifyDelegate: false)
        setNeedsLayout()
        delegate?.textInputViewDidChange(self)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.textInputViewDidChangeSelection(self)
        }
    }

    private func deleteBackwardAtAllSelections() {
        let selections = multiSelectionController.selections.sorted { $0.location > $1.location }
        var deleteOperations: [(deleteRange: NSRange, caretLocation: Int)] = []
        for selection in selections {
            if selection.length > 0 {
                deleteOperations.append((selection, selection.location))
                continue
            }
            guard selection.location > 0 else {
                continue
            }
            let characterRange = stringView.rangeOfComposedCharacterSequence(at: selection.location - 1)
            let deleteRange = NSRange(location: characterRange.location, length: selection.location - characterRange.location)
            deleteOperations.append((deleteRange, deleteRange.location))
        }
        guard !deleteOperations.isEmpty else {
            return
        }
        guard deleteOperations.allSatisfy({ shouldChangeText(in: $0.deleteRange, replacementText: "") }) else {
            return
        }
        timedUndoManager.beginIsolatedUndoGrouping()
        let primaryIndex = multiSelectionController.primaryIndex
        var newSelections: [NSRange] = []
        for operation in deleteOperations {
            replaceText(in: operation.deleteRange,
                       with: "",
                       selectedRangesAfterUndo: selections,
                       primaryIndexAfterUndo: primaryIndex,
                       updateSelection: false)
            newSelections.append(NSRange(location: operation.caretLocation, length: 0))
        }
        for selection in selections where selection.length == 0 && selection.location == 0 {
            newSelections.append(selection)
        }
        timedUndoManager.endUndoGrouping()
        applySelectedRanges(newSelections.sorted { $0.location < $1.location }, notifyDelegate: false)
        sendSelectionChangedToTextSelectionView()
        delegate?.textInputViewDidChange(self)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.textInputViewDidChangeSelection(self)
        }
    }

    private func deleteForwardAtAllSelections() {
        let selections = multiSelectionController.selections.sorted { $0.location > $1.location }
        var deleteOperations: [(deleteRange: NSRange, caretLocation: Int)] = []
        for selection in selections {
            if selection.length > 0 {
                deleteOperations.append((selection, selection.location))
                continue
            }
            guard selection.location < stringView.length else {
                continue
            }
            let deleteRange = stringView.rangeOfComposedCharacterSequence(at: selection.location)
            deleteOperations.append((deleteRange, selection.location))
        }
        guard !deleteOperations.isEmpty else {
            return
        }
        guard deleteOperations.allSatisfy({ shouldChangeText(in: $0.deleteRange, replacementText: "") }) else {
            return
        }
        timedUndoManager.beginIsolatedUndoGrouping()
        let primaryIndex = multiSelectionController.primaryIndex
        var newSelections: [NSRange] = []
        for operation in deleteOperations {
            replaceText(in: operation.deleteRange,
                       with: "",
                       selectedRangesAfterUndo: selections,
                       primaryIndexAfterUndo: primaryIndex,
                       updateSelection: false)
            newSelections.append(NSRange(location: operation.caretLocation, length: 0))
        }
        timedUndoManager.endUndoGrouping()
        applySelectedRanges(newSelections.sorted { $0.location < $1.location }, notifyDelegate: false)
        delegate?.textInputViewDidChange(self)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.textInputViewDidChangeSelection(self)
        }
    }
}

// MARK: - Selection
extension TextInputView {
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        if let indexedRange = range as? IndexedRange {
            return selectionRectService.selectionRects(in: indexedRange.range.nonNegativeLength)
        } else {
            return []
        }
    }

    private func safeSelectionRange(from range: NSRange) -> NSRange {
        let stringLength = stringView.length
        let cappedLocation = min(max(range.location, 0), stringLength)
        let cappedLength = min(max(range.length, 0), stringLength - cappedLocation)
        return NSRange(location: cappedLocation, length: cappedLength)
    }

    private func moveCaret(to linePosition: LinePosition) {
        if linePosition.row < lineManager.lineCount {
            let line = lineManager.line(atRow: linePosition.row)
            let location = line.location + min(linePosition.column, line.data.length)
            selection = NSRange(location: location, length: 0)
        } else {
            selection = nil
        }
    }

    private func sendSelectionChangedToTextSelectionView() {
        // The only way I've found to get the selection change to be reflected properly while still supporting Korean, Chinese, and deleting words with Option+Backspace is to call a private API in some cases. However, as pointed out by Alexander Blach in the following PR, there is another workaround to the issue.
        // When passing nil to the input delete, the text selection is update but the text input ignores it.
        // Even the Swift Playgrounds app does not get this right for all languages in all cases, so there seems to be some workarounds needed to due bugs in internal classes in UIKit that communicate with instances of UITextInput.
        inputDelegate?.selectionDidChange(nil)
    }
}

// MARK: - Indent and Outdent
extension TextInputView {
    func shiftLeft() {
        if multiSelectionController.hasMultipleSelections {
            shiftAllSelections(right: false)
        } else if let selection = selection {
            inputDelegate?.textWillChange(self)
            indentController.shiftLeft(in: selection)
            inputDelegate?.textDidChange(self)
        }
    }

    func shiftRight() {
        if multiSelectionController.hasMultipleSelections {
            shiftAllSelections(right: true)
        } else if let selection = selection {
            inputDelegate?.textWillChange(self)
            indentController.shiftRight(in: selection)
            inputDelegate?.textDidChange(self)
        }
    }

    /// Multi-cursor indent/outdent. `IndentController.shiftLeft/shiftRight(in:)` reports a single
    /// aggregate resulting range for whatever it's given, which can't be decomposed back into N
    /// independent carets when several selections land on the same or adjacent lines. Since
    /// neither operation is actually language-aware (both just prepend/remove one level of
    /// `indentStrategy.string(indentLevel: 1)` per line), it's simpler and exact to reimplement
    /// them here per distinct touched row — insert/remove directly, track the resulting delta for
    /// that row, and recompute every original selection's (row, column) against it afterward.
    private func shiftAllSelections(right: Bool) {
        let originalSelections = multiSelectionController.selections
        guard !originalSelections.isEmpty else {
            return
        }
        var rows = Set<Int>()
        for range in originalSelections {
            for line in lineManager.lines(in: range) {
                rows.insert(line.index)
            }
        }
        guard !rows.isEmpty else {
            return
        }
        var boundPairs: [(start: LinePosition, end: LinePosition)] = []
        for range in originalSelections {
            guard let startPosition = lineManager.linePosition(at: range.location),
                  let endPosition = lineManager.linePosition(at: range.upperBound) else {
                return
            }
            boundPairs.append((startPosition, endPosition))
        }
        let indentString = indentController.indentStrategy.string(indentLevel: 1)
        let indentLength = indentString.utf16.count
        var deltaByRow: [Int: Int] = [:]
        let primaryIndex = multiSelectionController.primaryIndex
        inputDelegate?.textWillChange(self)
        timedUndoManager.beginIsolatedUndoGrouping()
        // Descending row order: an edit at one row's start never shifts the location of a row
        // above it, so rows still to be processed are unaffected by ones already done.
        for row in rows.sorted(by: >) {
            let line = lineManager.line(atRow: row)
            if right {
                replaceText(in: NSRange(location: line.location, length: 0),
                           with: indentString,
                           selectedRangesAfterUndo: originalSelections,
                           primaryIndexAfterUndo: primaryIndex,
                           updateSelection: false)
                deltaByRow[row] = indentLength
            } else {
                let lineString = stringView.substring(in: NSRange(location: line.location, length: line.data.length)) ?? ""
                if lineString.hasPrefix(indentString) {
                    replaceText(in: NSRange(location: line.location, length: indentLength),
                               with: "",
                               selectedRangesAfterUndo: originalSelections,
                               primaryIndexAfterUndo: primaryIndex,
                               updateSelection: false)
                    deltaByRow[row] = -indentLength
                } else {
                    deltaByRow[row] = 0
                }
            }
        }
        timedUndoManager.endUndoGrouping()
        inputDelegate?.textDidChange(self)
        var newSelections: [NSRange] = []
        for pair in boundPairs {
            guard let startLocation = adjustedLocation(forRow: pair.start.row, column: pair.start.column, deltaByRow: deltaByRow),
                  let endLocation = adjustedLocation(forRow: pair.end.row, column: pair.end.column, deltaByRow: deltaByRow) else {
                continue
            }
            newSelections.append(NSRange(location: min(startLocation, endLocation), length: abs(endLocation - startLocation)))
        }
        guard !newSelections.isEmpty else {
            return
        }
        applySelectedRanges(newSelections.sorted { $0.location < $1.location })
    }

    /// Maps a pre-edit (row, column) to its post-edit document offset, using the per-row delta
    /// recorded while indenting/outdenting. Line count is unaffected by these operations, so rows
    /// still line up directly; only each row's own start (and thus every column on it) may have
    /// shifted by the row's own delta.
    private func adjustedLocation(forRow row: Int, column: Int, deltaByRow: [Int: Int]) -> Int? {
        location(forRow: row, column: column + (deltaByRow[row] ?? 0))
    }

    /// Resolves a (row, column) pair — as produced by `LineManager.linePosition(at:)` — back to a
    /// document offset, clamping the column to the row's own length. Shared by the multi-cursor
    /// indent, move-line, and line (duplicate/delete/select) batch operations, which all need to
    /// reconstruct carets from pre-edit (row, column) captures once their edits are done.
    func location(forRow row: Int, column: Int) -> Int? {
        guard row >= 0, row < lineManager.lineCount else {
            return nil
        }
        let line = lineManager.line(atRow: row)
        return line.location + min(max(column, 0), line.data.length)
    }

    /// Collapses every row touched by `ranges` into ascending, strictly-contiguous row groups.
    /// A group spans rows `n...m` only when every row between is also touched or adjacent, so
    /// two carets on directly neighbouring lines merge into one group while a gap of >=1 row
    /// keeps them separate. Shared by the move-line and line (duplicate/delete) batch paths,
    /// which both apply one edit per group and then rebuild carets.
    func contiguousRowGroups(in ranges: [NSRange]) -> [ClosedRange<Int>] {
        var rows = Set<Int>()
        for range in ranges {
            for line in lineManager.lines(in: range) {
                rows.insert(line.index)
            }
        }
        var groups: [ClosedRange<Int>] = []
        for row in rows.sorted() {
            if let last = groups.last, row == last.upperBound + 1 {
                groups[groups.count - 1] = last.lowerBound...row
            } else {
                groups.append(row...row)
            }
        }
        return groups
    }
}

// MARK: - Toggle Comment
extension TextInputView {
    /// Toggles the active language's line comment (⌘/) over every row touched by the current
    /// selection(s). Comments if any touched non-blank row lacks the prefix; otherwise uncomments.
    /// Multi-caret aware, one undo step, shape mirrors `shiftAllSelections` (indent/outdent):
    /// per-row edits in descending row order (so an edit never shifts a not-yet-processed row's
    /// location), then every original caret/selection is recomputed against the per-row deltas.
    /// No-op for a language with no `lineCommentPrefix` (e.g. plain text, or a Tree-sitter
    /// language that didn't configure one).
    func toggleComment() {
        guard let commentPrefix = languageMode.lineCommentPrefix, !commentPrefix.isEmpty else {
            return
        }
        let ranges = multiSelectionController.hasMultipleSelections
            ? multiSelectionController.selections
            : selection.map { [$0] } ?? []
        guard !ranges.isEmpty else {
            return
        }
        toggleComment(in: ranges, commentPrefix: commentPrefix)
    }

    private func toggleComment(in ranges: [NSRange], commentPrefix: String) {
        var rows = Set<Int>()
        for range in ranges {
            for line in lineManager.lines(in: range) {
                rows.insert(line.index)
            }
        }
        guard !rows.isEmpty else {
            return
        }
        var boundPairs: [(start: LinePosition, end: LinePosition)] = []
        for range in ranges {
            guard let startPosition = lineManager.linePosition(at: range.location),
                  let endPosition = lineManager.linePosition(at: range.upperBound) else {
                return
            }
            boundPairs.append((startPosition, endPosition))
        }
        let service = CommentToggleService(stringView: stringView, lineManager: lineManager, commentPrefix: commentPrefix)
        let direction = service.direction(forRows: rows)
        let rowEdits = service.edits(forRows: rows, direction: direction)
        guard !rowEdits.isEmpty else {
            return
        }
        var editByRow: [Int: (editColumn: Int, delta: Int)] = [:]
        let primaryIndex = multiSelectionController.hasMultipleSelections ? multiSelectionController.primaryIndex : 0
        inputDelegate?.textWillChange(self)
        timedUndoManager.beginIsolatedUndoGrouping()
        // Descending row order: an edit at one row's start never shifts the location of a row
        // above it, so rows still to be processed are unaffected by ones already done.
        for edit in rowEdits.sorted(by: { $0.row > $1.row }) {
            replaceText(in: edit.range,
                       with: edit.replacement,
                       selectedRangesAfterUndo: ranges,
                       primaryIndexAfterUndo: primaryIndex,
                       undoActionName: "Toggle Comment",
                       updateSelection: false)
            editByRow[edit.row] = (edit.editColumn, edit.delta)
        }
        timedUndoManager.endUndoGrouping()
        inputDelegate?.textDidChange(self)
        var newSelections: [NSRange] = []
        for pair in boundPairs {
            guard let startLocation = adjustedCommentLocation(forRow: pair.start.row, column: pair.start.column, editByRow: editByRow),
                  let endLocation = adjustedCommentLocation(forRow: pair.end.row, column: pair.end.column, editByRow: editByRow) else {
                continue
            }
            newSelections.append(NSRange(location: min(startLocation, endLocation), length: abs(endLocation - startLocation)))
        }
        guard !newSelections.isEmpty else {
            return
        }
        if newSelections.count == 1 {
            selection = newSelections[0]
            selectionAnchor = newSelections[0].location
        } else {
            applySelectedRanges(MultiSelectionController.normalize(newSelections))
        }
    }

    /// Maps a pre-edit (row, column) to its post-edit document offset. Unlike indent/outdent's
    /// `adjustedLocation` (whose edit always sits at column 0, so every column on the row shifts
    /// uniformly), a comment edit sits at the row's leading-whitespace boundary: a caret at or
    /// after that column shifts by the row's delta; one strictly before it (inside the leading
    /// whitespace) does not.
    private func adjustedCommentLocation(forRow row: Int, column: Int, editByRow: [Int: (editColumn: Int, delta: Int)]) -> Int? {
        guard let edit = editByRow[row] else {
            return location(forRow: row, column: column)
        }
        let adjustedColumn = column >= edit.editColumn ? column + edit.delta : column
        return location(forRow: row, column: adjustedColumn)
    }
}

// MARK: - Move Lines
extension TextInputView {
    func moveSelectedLinesUp() {
        if multiSelectionController.hasMultipleSelections {
            moveAllSelectedLines(byOffset: -1, undoActionName: L10n.Undo.ActionName.moveLinesUp)
        } else {
            moveSelectedLine(byOffset: -1, undoActionName: L10n.Undo.ActionName.moveLinesUp)
        }
    }

    func moveSelectedLinesDown() {
        if multiSelectionController.hasMultipleSelections {
            moveAllSelectedLines(byOffset: 1, undoActionName: L10n.Undo.ActionName.moveLinesDown)
        } else {
            moveSelectedLine(byOffset: 1, undoActionName: L10n.Undo.ActionName.moveLinesDown)
        }
    }

    private func moveSelectedLine(byOffset lineOffset: Int, undoActionName: String) {
        guard let oldSelectedRange = selection else {
            return
        }
        let moveLinesService = MoveLinesService(stringView: stringView, lineManager: lineManager, lineEndingSymbol: lineEndings.symbol)
        guard let operation = moveLinesService.operationForMovingLines(in: oldSelectedRange, byOffset: lineOffset) else {
            return
        }
        timedUndoManager.endUndoGrouping()
        timedUndoManager.beginUndoGrouping()
        replaceText(in: operation.removeRange, with: "", undoActionName: undoActionName)
        replaceText(in: operation.replacementRange, with: operation.replacementString, undoActionName: undoActionName)
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        selection = operation.selectedRange
        timedUndoManager.endUndoGrouping()
    }

    /// Multi-cursor move-line. `MoveLinesService` computes one group's move as a pure row-range
    /// relocation that preserves relative row order and column offsets within the group and
    /// leaves the total document length unchanged, so every original selection's row simply
    /// becomes `row + lineOffset` afterward with its column unchanged — no per-character delta
    /// bookkeeping is needed here, unlike indent.
    ///
    /// Groups come from `contiguousRowGroups(in:)` — strictly contiguous rows. Each group
    /// also touches one row *beyond* itself — its target row, immediately above (up) or below
    /// (down) the group — but that never collides with a neighboring group's own rows as long as
    /// the two aren't directly adjacent: a gap of >=1 row always leaves at least one full row of
    /// clearance between one group's target and the next group's nearest row, in either
    /// direction. Two directly-adjacent groups (gap 0) are already merged into one by the
    /// contiguous-row grouping itself, so no extra gap tolerance is needed here.
    ///
    /// Processing order is top-to-bottom for an upward move and bottom-to-top for a downward one,
    /// so a group's target row is always still in its pre-move position when that group is
    /// processed. The whole operation aborts — leaving nothing modified, since operations are
    /// only applied after every group has been validated — if any group would run off the
    /// document edge.
    private func moveAllSelectedLines(byOffset lineOffset: Int, undoActionName: String) {
        let originalSelections = multiSelectionController.selections
        guard !originalSelections.isEmpty else {
            return
        }
        let groups = contiguousRowGroups(in: originalSelections)
        guard !groups.isEmpty else {
            return
        }
        var boundPairs: [(start: LinePosition, end: LinePosition)] = []
        for range in originalSelections {
            guard let startPosition = lineManager.linePosition(at: range.location),
                  let endPosition = lineManager.linePosition(at: range.upperBound) else {
                return
            }
            boundPairs.append((startPosition, endPosition))
        }
        let orderedGroups = lineOffset < 0
            ? groups.sorted { $0.lowerBound < $1.lowerBound }
            : groups.sorted { $0.lowerBound > $1.lowerBound }
        var operations: [MoveLinesOperation] = []
        let moveLinesService = MoveLinesService(stringView: stringView, lineManager: lineManager, lineEndingSymbol: lineEndings.symbol)
        for group in orderedGroups {
            let firstLine = lineManager.line(atRow: group.lowerBound)
            let lastLine = lineManager.line(atRow: group.upperBound)
            let groupRange = NSRange(location: firstLine.location, length: (lastLine.location + lastLine.data.length) - firstLine.location)
            guard let operation = moveLinesService.operationForMovingLines(in: groupRange, byOffset: lineOffset) else {
                // A group would run off the document edge -- abort without modifying anything.
                return
            }
            operations.append(operation)
        }
        timedUndoManager.endUndoGrouping()
        timedUndoManager.beginUndoGrouping()
        let primaryIndex = multiSelectionController.primaryIndex
        for operation in operations {
            replaceText(in: operation.removeRange,
                       with: "",
                       selectedRangesAfterUndo: originalSelections,
                       primaryIndexAfterUndo: primaryIndex,
                       undoActionName: undoActionName,
                       updateSelection: false)
            replaceText(in: operation.replacementRange,
                       with: operation.replacementString,
                       selectedRangesAfterUndo: originalSelections,
                       primaryIndexAfterUndo: primaryIndex,
                       undoActionName: undoActionName,
                       updateSelection: false)
        }
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        var newSelections: [NSRange] = []
        for pair in boundPairs {
            guard let startLocation = location(forRow: pair.start.row + lineOffset, column: pair.start.column),
                  let endLocation = location(forRow: pair.end.row + lineOffset, column: pair.end.column) else {
                continue
            }
            newSelections.append(NSRange(location: min(startLocation, endLocation), length: abs(endLocation - startLocation)))
        }
        timedUndoManager.endUndoGrouping()
        guard !newSelections.isEmpty else {
            return
        }
        applySelectedRanges(newSelections.sorted { $0.location < $1.location })
    }
}

// MARK: - Line Operations
extension TextInputView {
    /// Snaps every selection out to the full extent of the line(s) it touches, trailing line
    /// break included (⌘L). Single-shot: because `startAndEndLine(in:)` resolves the end line
    /// from `upperBound - 1`, running it again on the resulting range reproduces that same range.
    /// Works per selection when multiple carets are active; colliding line spans are merged by
    /// `MultiSelectionController.normalize`.
    func selectLines() {
        let ranges = selectedRanges
        guard !ranges.isEmpty else {
            return
        }
        var newRanges: [NSRange] = []
        for range in ranges {
            guard let (startLine, endLine) = lineManager.startAndEndLine(in: range) else {
                continue
            }
            let location = startLine.location
            let length = endLine.location + endLine.data.totalLength - location
            newRanges.append(NSRange(location: location, length: length))
        }
        guard !newRanges.isEmpty else {
            return
        }
        pushCaretHistory()
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        applySelectedRanges(newRanges)
    }

    /// Inserts a copy of every line touched by the current selection immediately below it, in one
    /// undo step (⌘D). Each contiguous run of touched rows is copied as a block; the caret set
    /// moves onto the copy (VS Code / Sublime behaviour) — a selection at row `r` in a group ends
    /// up shifted down by that group's own height plus the combined height of every group above
    /// it. When the last line has no trailing line break the copy is prefixed with one so it
    /// still lands on its own line. Multi-caret aware; a plain caret is just the one-selection
    /// case.
    func duplicateSelectedLines() {
        let originalSelections = selectedRanges
        guard !originalSelections.isEmpty else {
            return
        }
        let groups = contiguousRowGroups(in: originalSelections)
        guard !groups.isEmpty else {
            return
        }
        var boundPairs: [(start: LinePosition, end: LinePosition)] = []
        for range in originalSelections {
            guard let startPosition = lineManager.linePosition(at: range.location),
                  let endPosition = lineManager.linePosition(at: range.upperBound) else {
                return
            }
            boundPairs.append((startPosition, endPosition))
        }
        var insertions: [(location: Int, text: String)] = []
        for group in groups {
            let firstLine = lineManager.line(atRow: group.lowerBound)
            let lastLine = lineManager.line(atRow: group.upperBound)
            let blockRange = NSRange(location: firstLine.location,
                                     length: lastLine.location + lastLine.data.totalLength - firstLine.location)
            guard let blockText = stringView.substring(in: blockRange) else {
                return
            }
            let text = lastLine.data.delimiterLength == 0 ? lineEndings.symbol + blockText : blockText
            insertions.append((location: blockRange.upperBound, text: text))
        }
        guard insertions.allSatisfy({ shouldChangeText(in: NSRange(location: $0.location, length: 0), replacementText: $0.text) }) else {
            return
        }
        timedUndoManager.beginIsolatedUndoGrouping()
        let primaryIndex = multiSelectionController.primaryIndex
        // Bottom-to-top so an earlier insertion never shifts a later one's location.
        for insertion in insertions.sorted(by: { $0.location > $1.location }) {
            replaceText(in: NSRange(location: insertion.location, length: 0),
                       with: insertion.text,
                       selectedRangesAfterUndo: originalSelections,
                       primaryIndexAfterUndo: primaryIndex,
                       undoActionName: L10n.Undo.ActionName.duplicateLines,
                       updateSelection: false)
        }
        timedUndoManager.endUndoGrouping()
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        let sortedGroups = groups.sorted { $0.lowerBound < $1.lowerBound }
        var newSelections: [NSRange] = []
        for pair in boundPairs {
            let shift = duplicateRowShift(forRow: pair.start.row, groups: sortedGroups)
            guard let startLocation = location(forRow: pair.start.row + shift, column: pair.start.column),
                  let endLocation = location(forRow: pair.end.row + shift, column: pair.end.column) else {
                continue
            }
            newSelections.append(NSRange(location: min(startLocation, endLocation), length: abs(endLocation - startLocation)))
        }
        guard !newSelections.isEmpty else {
            return
        }
        applySelectedRanges(newSelections.sorted { $0.location < $1.location })
    }

    /// Deletes every line touched by the current selection, in one undo step (⌘⌫). Each
    /// contiguous run of touched rows is removed as a block; each caret then lands at the start
    /// of whatever line slid up into the group's first row, column preserved and clamped, shifted
    /// up by every row deleted above it. When the block ends at a final line that has no trailing
    /// line break the preceding delimiter is swallowed too, so no blank line is left behind.
    /// Deleting the whole document leaves a single empty line with the caret at the start.
    func deleteSelectedLines() {
        let originalSelections = selectedRanges
        guard !originalSelections.isEmpty else {
            return
        }
        let groups = contiguousRowGroups(in: originalSelections)
        guard !groups.isEmpty else {
            return
        }
        var targets: [(row: Int, column: Int)] = []
        for range in originalSelections {
            guard let position = lineManager.linePosition(at: range.location) else {
                return
            }
            targets.append((position.row, position.column))
        }
        var deleteRanges: [NSRange] = []
        for group in groups {
            let firstLine = lineManager.line(atRow: group.lowerBound)
            let lastLine = lineManager.line(atRow: group.upperBound)
            var start = firstLine.location
            let end = lastLine.location + lastLine.data.totalLength
            if lastLine.data.delimiterLength == 0, group.lowerBound > 0 {
                let previousLine = lineManager.line(atRow: group.lowerBound - 1)
                start = previousLine.location + previousLine.data.length
            }
            deleteRanges.append(NSRange(location: start, length: end - start))
        }
        guard deleteRanges.allSatisfy({ shouldChangeText(in: $0, replacementText: "") }) else {
            return
        }
        timedUndoManager.beginIsolatedUndoGrouping()
        let primaryIndex = multiSelectionController.primaryIndex
        for range in deleteRanges.sorted(by: { $0.location > $1.location }) {
            replaceText(in: range,
                       with: "",
                       selectedRangesAfterUndo: originalSelections,
                       primaryIndexAfterUndo: primaryIndex,
                       undoActionName: L10n.Undo.ActionName.deleteLines,
                       updateSelection: false)
        }
        timedUndoManager.endUndoGrouping()
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        let sortedGroups = groups.sorted { $0.lowerBound < $1.lowerBound }
        let newLineCount = lineManager.lineCount
        var newSelections: [NSRange] = []
        for target in targets {
            var rowsDeletedAbove = 0
            var landingRow = target.row
            for group in sortedGroups {
                if group.contains(target.row) {
                    landingRow = group.lowerBound - rowsDeletedAbove
                    break
                }
                if group.upperBound < target.row {
                    rowsDeletedAbove += group.count
                }
            }
            let clampedRow = max(0, min(landingRow, newLineCount - 1))
            guard let caretLocation = location(forRow: clampedRow, column: target.column) else {
                continue
            }
            newSelections.append(NSRange(location: caretLocation, length: 0))
        }
        if newSelections.isEmpty {
            newSelections = [NSRange(location: 0, length: 0)]
        }
        applySelectedRanges(newSelections.sorted { $0.location < $1.location })
    }

    /// Downward row shift a caret at `row` receives from `duplicateSelectedLines()`: the height of
    /// its own (sorted, ascending) group plus the combined height of every group above it. `row`
    /// is guaranteed to fall inside exactly one group, since the groups are derived from the
    /// selections themselves.
    private func duplicateRowShift(forRow row: Int, groups: [ClosedRange<Int>]) -> Int {
        var cumulative = 0
        for group in groups {
            if group.contains(row) {
                return cumulative + group.count
            }
            cumulative += group.count
        }
        return cumulative
    }

    /// Inserts a new, empty (but indent-matched) line above or below every row touched by the
    /// current selection(s) (⌘⏎ / ⌘⇧⏎), one undo step. Unlike duplicate/delete, the resulting
    /// carets don't need to track the original selections' content — every caret simply lands on
    /// its own freshly inserted blank line, so this only needs row-level dedup, not the
    /// group/shift bookkeeping `duplicateSelectedLines` needs to preserve original content.
    func insertLine(above: Bool) {
        let originalSelections = selectedRanges
        guard !originalSelections.isEmpty else {
            return
        }
        var rows = Set<Int>()
        for range in originalSelections {
            for line in lineManager.lines(in: range) {
                rows.insert(line.index)
            }
        }
        guard !rows.isEmpty else {
            return
        }
        // Sorted ascending: row `sortedRows[i]` has exactly `i` new lines inserted somewhere
        // before it in the document (one per earlier row in this list), so once every edit has
        // landed its own new blank line sits at final row `row + i` (above) / `row + i + 1`
        // (below) — used below to relocate carets *after* editing, not tracked through the edits.
        let sortedRows = rows.sorted()
        struct Insertion {
            let row: Int
            let location: Int
            let text: String
            let indentUTF16Length: Int
        }
        var insertions: [Insertion] = []
        for row in sortedRows {
            let line = lineManager.line(atRow: row)
            let content = stringView.substring(in: NSRange(location: line.location, length: line.data.length)) ?? ""
            let indent = String(content.prefix { $0 == " " || $0 == "\t" })
            if above {
                let text = indent + lineEndings.symbol
                insertions.append(Insertion(row: row, location: line.location, text: text, indentUTF16Length: indent.utf16.count))
            } else if line.data.delimiterLength > 0 {
                // A delimiter already separates this line from the next — the new line's own
                // text is `indent + delimiter`, inserted right at the next line's start.
                let text = indent + lineEndings.symbol
                insertions.append(Insertion(row: row, location: line.location + line.data.totalLength, text: text, indentUTF16Length: indent.utf16.count))
            } else {
                // Last line of the document, no trailing delimiter yet — the new line needs its
                // own leading delimiter instead.
                let text = lineEndings.symbol + indent
                insertions.append(Insertion(row: row, location: line.location + line.data.length, text: text, indentUTF16Length: indent.utf16.count))
            }
        }
        guard insertions.allSatisfy({ shouldChangeText(in: NSRange(location: $0.location, length: 0), replacementText: $0.text) }) else {
            return
        }
        timedUndoManager.beginIsolatedUndoGrouping()
        let primaryIndex = multiSelectionController.hasMultipleSelections ? multiSelectionController.primaryIndex : 0
        // Bottom-to-top so an earlier (higher-location) insertion never invalidates a later
        // (lower-location) insertion's precomputed location.
        for insertion in insertions.sorted(by: { $0.location > $1.location }) {
            replaceText(in: NSRange(location: insertion.location, length: 0),
                       with: insertion.text,
                       selectedRangesAfterUndo: originalSelections,
                       primaryIndexAfterUndo: primaryIndex,
                       undoActionName: above ? "Insert Line Above" : "Insert Line Below",
                       updateSelection: false)
        }
        timedUndoManager.endUndoGrouping()
        // Relocate every caret *after* all edits have landed — row count changed, so an offset
        // computed mid-loop (like `insertion.location`) would go stale as soon as a later,
        // lower-location insertion pushed it forward. `location(forRow:column:)` re-resolves
        // against the now-fully-updated `lineManager` instead.
        var newSelections: [NSRange] = []
        for (index, insertion) in insertions.enumerated() {
            let finalRow = above ? insertion.row + index : insertion.row + index + 1
            guard let caretLocation = location(forRow: finalRow, column: insertion.indentUTF16Length) else {
                continue
            }
            newSelections.append(NSRange(location: caretLocation, length: 0))
        }
        guard !newSelections.isEmpty else {
            return
        }
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        if newSelections.count == 1 {
            selection = newSelections[0]
            selectionAnchor = newSelections[0].location
        } else {
            applySelectedRanges(newSelections.sorted { $0.location < $1.location })
        }
    }

    /// Sorts every contiguous block of rows touched by the current selection(s), independently,
    /// one undo step. A block of one row is left alone (nothing to reorder). The sorted block(s)
    /// become the new selection, since the original carets' positions no longer correspond to
    /// meaningful content after a reorder.
    func sortSelectedLines(descending: Bool) {
        let originalSelections = selectedRanges
        guard !originalSelections.isEmpty else {
            return
        }
        let groups = contiguousRowGroups(in: originalSelections)
        let service = LineSortService(stringView: stringView, lineManager: lineManager, lineEndingSymbol: lineEndings.symbol)
        let operations = groups.compactMap { service.sortOperation(forRows: $0, descending: descending) }
        guard !operations.isEmpty,
              operations.allSatisfy({ shouldChangeText(in: $0.range, replacementText: $0.replacement) }) else {
            return
        }
        let primaryIndex = multiSelectionController.hasMultipleSelections ? multiSelectionController.primaryIndex : 0
        timedUndoManager.beginIsolatedUndoGrouping()
        // Bottom-to-top so an earlier block's replacement never shifts a later block's
        // precomputed range.
        for operation in operations.sorted(by: { $0.range.location > $1.range.location }) {
            replaceText(in: operation.range,
                       with: operation.replacement,
                       selectedRangesAfterUndo: originalSelections,
                       primaryIndexAfterUndo: primaryIndex,
                       undoActionName: descending ? "Sort Lines Descending" : "Sort Lines Ascending",
                       updateSelection: false)
        }
        timedUndoManager.endUndoGrouping()
        // Row count is unaffected by a reorder, so every group's rows still line up directly;
        // re-derive each block's final range fresh now that all edits are applied.
        var newSelections: [NSRange] = []
        for group in groups where group.upperBound < lineManager.lineCount {
            let firstLine = lineManager.line(atRow: group.lowerBound)
            let lastLine = lineManager.line(atRow: group.upperBound)
            newSelections.append(NSRange(
                location: firstLine.location,
                length: lastLine.location + lastLine.data.totalLength - firstLine.location
            ))
        }
        guard !newSelections.isEmpty else {
            return
        }
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        applySelectedRanges(newSelections.sorted { $0.location < $1.location })
    }
}

// MARK: - Marking
extension TextInputView {
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        applyMarkedText(markedText, selectedRange: selectedRange)
    }

    private func applyMarkedText(_ markedText: String?, selectedRange markedSelectedRange: NSRange) {
        guard let range = imeMarkedRange ?? self.selection else {
            return
        }
        let markedText = markedText ?? ""
        guard shouldChangeText(in: range, replacementText: markedText) else {
            return
        }
        imeMarkedRange = markedText.isEmpty ? nil : NSRange(location: range.location, length: markedText.utf16.count)
        replaceText(in: range, with: markedText)
        // The selected range passed to setMarkedText(_:selectedRange:) is local to the marked range.
        let preferredSelectedRange = NSRange(location: range.location + markedSelectedRange.location, length: markedSelectedRange.length)
        inputDelegate?.selectionWillChange(self)
        _selectedRange = safeSelectionRange(from: preferredSelectedRange)
        inputDelegate?.selectionDidChange(self)
        delegate?.textInputViewDidUpdateMarkedRange(self)
    }

    func unmarkText() {
        inputDelegate?.selectionWillChange(self)
        imeMarkedRange = nil
        inputDelegate?.selectionDidChange(self)
        delegate?.textInputViewDidUpdateMarkedRange(self)
    }
}

// MARK: - Ranges and Positions
extension TextInputView {
    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        // This implementation seems to match the behavior of UITextView.
        guard let indexedRange = range as? IndexedRange else {
            return nil
        }
        switch direction {
        case .left, .up:
            return IndexedPosition(index: indexedRange.range.lowerBound)
        case .right, .down:
            return IndexedPosition(index: indexedRange.range.upperBound)
        @unknown default:
            return nil
        }
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard let indexedPosition = position as? IndexedPosition else {
            return nil
        }
        didCallPositionFromPositionInDirectionWithOffset = true
        guard let newLocation = lineMovementController.location(from: indexedPosition.index, in: direction, offset: offset) else {
            return nil
        }
        return IndexedPosition(index: newLocation)
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        // This implementation seems to match the behavior of UITextView.
        guard let indexedPosition = position as? IndexedPosition else {
            return nil
        }
        switch direction {
        case .left, .up:
            let leftIndex = max(indexedPosition.index - 1, 0)
            return IndexedRange(location: leftIndex, length: indexedPosition.index - leftIndex)
        case .right, .down:
            let rightIndex = min(indexedPosition.index + 1, stringView.length)
            return IndexedRange(location: indexedPosition.index, length: rightIndex - indexedPosition.index)
        @unknown default:
            return nil
        }
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let index = layoutManager.closestIndex(to: point) else {
            return nil
        }
        let cappedIndex = max(index - 1, 0)
        let range = stringView.rangeOfComposedCharacterSequence(at: cappedIndex)
        return IndexedRange(range)
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        if let index = layoutManager.closestIndex(to: point) {
            return IndexedPosition(index: index)
        } else {
            return nil
        }
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let indexedRange = range as? IndexedRange else {
            return nil
        }
        guard let index = layoutManager.closestIndex(to: point) else {
            return nil
        }
        let minimumIndex = indexedRange.range.lowerBound
        let maximumIndex = indexedRange.range.upperBound
        let cappedIndex = min(max(index, minimumIndex), maximumIndex)
        return IndexedPosition(index: cappedIndex)
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let fromIndexedPosition = fromPosition as? IndexedPosition, let toIndexedPosition = toPosition as? IndexedPosition else {
            return nil
        }
        let range = NSRange(location: fromIndexedPosition.index, length: toIndexedPosition.index - fromIndexedPosition.index)
        return IndexedRange(range)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let indexedPosition = position as? IndexedPosition else {
            return nil
        }
        let newPosition = indexedPosition.index + offset
        guard newPosition >= 0 && newPosition <= stringView.length else {
            return nil
        }
        return IndexedPosition(index: newPosition)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let indexedPosition = position as? IndexedPosition, let otherIndexedPosition = other as? IndexedPosition else {
            #if targetEnvironment(macCatalyst)
            // Mac Catalyst may pass <uninitialized> to `position`. I'm not sure what the right way to deal with that is but returning .orderedSame seems to work.
            return .orderedSame
            #else
            fatalError("Positions must be of type \(IndexedPosition.self)")
            #endif
        }
        if indexedPosition.index < otherIndexedPosition.index {
            return .orderedAscending
        } else if indexedPosition.index > otherIndexedPosition.index {
            return .orderedDescending
        } else {
            return .orderedSame
        }
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        if let fromPosition = from as? IndexedPosition, let toPosition = toPosition as? IndexedPosition {
            return toPosition.index - fromPosition.index
        } else {
            return 0
        }
    }
}

// MARK: - Writing Direction
extension TextInputView {
    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .natural
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}
}

// MARK: - Context Menu
extension TextInputView {
    func presentEditMenuForText(in range: NSRange) {
        editMenuController.presentEditMenu(from: self, forTextIn: range)
    }

    func showContextMenu(with event: NSEvent) {
        editMenuController.presentContextMenu(for: self, with: event)
    }

    @objc func replaceTextInSelectedHighlightedRange() {
        if let selection = selection, let highlightedRange = highlightedRange(for: selection) {
            delegate?.textInputView(self, replaceTextIn: highlightedRange)
        }
    }

    private func highlightedRange(for range: NSRange) -> HighlightedRange? {
        highlightedRanges.first { $0.range == range }
    }
}

// MARK: - TreeSitterLanguageModeDeleage
extension TextInputView: TreeSitterLanguageModeDelegate {
    nonisolated func treeSitterLanguageMode(_ languageMode: TreeSitterInternalLanguageMode, bytesAt byteIndex: ByteCount) -> TreeSitterTextProviderResult? {
        languageMode.readBytes(at: byteIndex)
    }
}

// MARK: - LineControllerStorageDelegate
extension TextInputView: @preconcurrency LineControllerStorageDelegate {
    func lineControllerStorage(_ storage: LineControllerStorage, didCreate lineController: LineController) {
        lineController.delegate = self
        lineController.constrainingWidth = layoutManager.constrainingLineWidth
        lineController.estimatedLineFragmentHeight = theme.font.totalLineHeight
        lineController.lineFragmentHeightMultiplier = lineHeightMultiplier
        lineController.tabWidth = indentController.tabWidth
        lineController.theme = theme
        lineController.lineBreakMode = lineBreakMode
    }
}

// MARK: - LineControllerDelegate
extension TextInputView: @preconcurrency LineControllerDelegate {
    func lineSyntaxHighlighter(for lineController: LineController) -> LineSyntaxHighlighter? {
        let highlighter = languageMode.createLineSyntaxHighlighter()
        (highlighter as? TreeSitterSyntaxHighlighter)?.semanticHighlights = semanticHighlights
        return highlighter
    }

    func lineControllerDidInvalidateLineWidthDuringAsyncSyntaxHighlight(_ lineController: LineController) {
        setNeedsLayout()
        layoutManager.setNeedsLayout()
        scheduleDeferredLayoutIfNeeded()
    }

    func lineControllerDidRefreshDisplayedLineFragments(_ lineController: LineController) {
        layoutManager.refreshMetalGlyphsAfterSyntaxHighlight(for: lineController.line.id)
        scheduleDeferredLayoutIfNeeded()
    }
}

// MARK: - LayoutManagerDelegate
extension TextInputView: LayoutManagerDelegate {
    func layoutManager(_ layoutManager: LayoutManager, didProposeContentOffsetAdjustment contentOffsetAdjustment: CGPoint) {
        delegate?.textInputView(self, didProposeContentOffsetAdjustment: contentOffsetAdjustment)
    }
}

// MARK: - IndentControllerDelegate
extension TextInputView: IndentControllerDelegate {
    func indentController(_ controller: IndentController, shouldInsert text: String, in range: NSRange) {
        if let restore = pendingMultiSelectionUndoRestore {
            replaceText(in: range, with: text, selectedRangesAfterUndo: restore.ranges, primaryIndexAfterUndo: restore.primaryIndex)
        } else {
            replaceText(in: range, with: text)
        }
    }

    func indentController(_ controller: IndentController, shouldSelect range: NSRange) {
        inputDelegate?.selectionWillChange(self)
        selection = range
        inputDelegate?.selectionDidChange(self)
    }

    func indentControllerDidUpdateTabWidth(_ controller: IndentController) {
        invalidateLines()
    }
}

// MARK: - EditMenuControllerDelegate
extension TextInputView: EditMenuControllerDelegate {
    func editMenuController(_ controller: EditMenuController, caretRectAt location: Int) -> CGRect {
        caretRectService.caretRect(at: location, allowMovingCaretToNextLineFragment: false)
    }

    func editMenuControllerShouldReplaceText(_ controller: EditMenuController) {
        replaceTextInSelectedHighlightedRange()
    }

    func editMenuController(_ controller: EditMenuController, canReplaceTextIn highlightedRange: HighlightedRange) -> Bool {
        delegate?.textInputView(self, canReplaceTextIn: highlightedRange) ?? false
    }

    func editMenuController(_ controller: EditMenuController, highlightedRangeFor range: NSRange) -> HighlightedRange? {
        highlightedRange(for: range)
    }

    func selectedRange(for controller: EditMenuController) -> NSRange? {
        selection
    }

    func editMenuControllerIsEditable(_ controller: EditMenuController) -> Bool {
        delegate?.textInputViewIsEditable(self) ?? true
    }
}

// MARK: - IntelliJ-style actions
extension TextInputView {
    /// Toggles sticky column/block selection mode (⌘⇧8).
    func toggleColumnSelectionMode() {
        if blockSelectionController.isStickyModeEnabled {
            endBlockSelection()
            collapseMultiSelectionToPrimary()
        } else {
            beginBlockSelectionAtCurrentCaretIfNeeded()
            blockSelectionController.isStickyModeEnabled = true
            applyMaterializedBlockSelectionIfActive()
        }
    }

    private func applyMaterializedBlockSelectionIfActive() {
        guard blockSelectionController.isActive else { return }
        extendBlockSelection(in: .right)
        extendBlockSelection(in: .left)
    }

    // MARK: Semantic selection

    private var treeSitterLanguageMode: TreeSitterInternalLanguageMode? {
        languageMode as? TreeSitterInternalLanguageMode
    }

    func expandSemanticSelection() {
        guard let current = selection else { return }
        pushCaretHistory()
        guard let next = semanticSelectionController.expand(from: current, candidates: { [weak self] in
            self?.semanticSelectionCandidates(for: current) ?? []
        }) else {
            return
        }
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        selection = next
        selectionAnchor = next.location
    }

    func shrinkSemanticSelection() {
        guard let current = selection, let previous = semanticSelectionController.shrink(from: current) else {
            return
        }
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        selection = previous
        selectionAnchor = previous.location
    }

    /// Increasing ranges that each strictly contain `current`: the word at the caret, then
    /// every enclosing syntax-node range, or word → line → paragraph → document without a tree.
    private func semanticSelectionCandidates(for current: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        let documentRange = NSRange(location: 0, length: string.length)

        if let word = SelectNextOccurrence.wordRange(at: current.location, documentLength: string.length, tokenizer: tokenizer) {
            result.append(word)
        }

        // Probe from inside the current selection (its midpoint) so a zero-width query at a
        // token boundary doesn't resolve to the previous token.
        let probe = min(max(current.location + current.length / 2, current.location), max(string.length - 1, 0))
        if let languageMode = treeSitterLanguageMode,
           let probePosition = lineManager.linePosition(at: probe),
           var node = languageMode.treeSitterNode(at: probePosition) {
            var visited = 0
            while visited < 512 {
                visited += 1
                let byteRange = node.byteRange
                let range = NSRange(location: byteRange.location.utf16Length, length: byteRange.length.utf16Length)
                if range.location <= current.location, range.upperBound >= current.upperBound, range.length > current.length {
                    result.append(range)
                }
                guard let parent = node.parent else { break }
                node = parent
            }
        } else {
            if let (startLine, endLine) = lineManager.startAndEndLine(in: current) {
                let location = startLine.location
                let length = endLine.location + endLine.data.totalLength - location
                result.append(NSRange(location: location, length: length))
            }
        }

        result.append(documentRange)
        // Trim whitespace edges (a semantic selection shouldn't start or end on a space),
        // then keep only ranges that still strictly enclose `current`; de-dup; sort ascending.
        var seen = Set<NSRange>()
        return result
            .map { trimmingWhitespace($0) }
            .filter { $0.location <= current.location && $0.upperBound >= current.upperBound && $0.length > current.length }
            .filter { seen.insert($0).inserted }
            .sorted { $0.length < $1.length }
    }

    private func trimmingWhitespace(_ range: NSRange) -> NSRange {
        var start = range.location
        var end = range.upperBound
        let whitespace = CharacterSet.whitespacesAndNewlines
        while start < end,
              let scalar = string.substring(with: NSRange(location: start, length: 1)).unicodeScalars.first,
              whitespace.contains(scalar) {
            start += 1
        }
        while end > start,
              let scalar = string.substring(with: NSRange(location: end - 1, length: 1)).unicodeScalars.first,
              whitespace.contains(scalar) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Move statement

    func moveSelectedStatements(byOffset offset: Int) {
        guard let current = selection else { return }
        let rowRange = statementRowRange(for: current) ?? fallbackRowRange(for: current)
        guard let rowRange else {
            return
        }
        let firstLine = lineManager.line(atRow: rowRange.lowerBound)
        let lastLine = lineManager.line(atRow: rowRange.upperBound)
        let statementRange = NSRange(
            location: firstLine.location,
            length: lastLine.location + lastLine.data.totalLength - firstLine.location
        )
        let service = MoveLinesService(stringView: stringView, lineManager: lineManager, lineEndingSymbol: lineEndings.symbol)
        guard let operation = service.operationForMovingLines(in: statementRange, byOffset: offset) else {
            return
        }
        let undoName = offset < 0 ? L10n.Undo.ActionName.moveStatementUp : L10n.Undo.ActionName.moveStatementDown
        timedUndoManager.endUndoGrouping()
        timedUndoManager.beginUndoGrouping()
        replaceText(in: operation.removeRange, with: "", undoActionName: undoName)
        replaceText(in: operation.replacementRange, with: operation.replacementString, undoActionName: undoName)
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        selection = operation.selectedRange
        timedUndoManager.endUndoGrouping()
    }

    private func statementRowRange(for range: NSRange) -> ClosedRange<Int>? {
        guard let languageMode = treeSitterLanguageMode,
              let position = lineManager.linePosition(at: range.location),
              let node = languageMode.treeSitterNode(at: position) else {
            return nil
        }
        return StatementRangeService().statementRowRange(around: node)
    }

    private func fallbackRowRange(for range: NSRange) -> ClosedRange<Int>? {
        guard let start = lineManager.linePosition(at: range.location),
              let end = lineManager.linePosition(at: range.upperBound) else {
            return nil
        }
        return min(start.row, end.row)...max(start.row, end.row)
    }

    // MARK: Join lines

    /// Joins lines for every caret (⌃⇧J). A single-row caret joins its line with the next; a
    /// multi-row selection joins every line it spans. Multi-caret aware, one undo step; each
    /// caret ends at its own join point.
    func joinSelectedLines() {
        let ranges = selectedRanges
        guard !ranges.isEmpty else { return }

        // How many joins each starting row needs (dedup overlapping selections, keep the max).
        var joinsByRow: [Int: Int] = [:]
        for range in ranges {
            guard let start = lineManager.linePosition(at: range.location),
                  let end = lineManager.linePosition(at: range.upperBound) else {
                continue
            }
            let lastRow = end.row == start.row ? start.row + 1 : end.row
            joinsByRow[start.row] = max(joinsByRow[start.row] ?? 0, max(1, lastRow - start.row))
        }
        guard !joinsByRow.isEmpty else { return }

        let service = JoinLinesService(stringView: stringView, lineManager: lineManager)
        timedUndoManager.endUndoGrouping()
        timedUndoManager.beginUndoGrouping()

        // Process top-to-bottom, shifting each later start row up by the joins already done
        // above it; record each caret target as (row, column) to resolve once at the end.
        var caretTargets: [(row: Int, column: Int)] = []
        var rowShift = 0
        for originalRow in joinsByRow.keys.sorted() {
            let firstRow = originalRow - rowShift
            var joinsRemaining = joinsByRow[originalRow] ?? 0
            var joinsDone = 0
            var caretColumn = 0
            while joinsRemaining > 0,
                  firstRow >= 0,
                  firstRow + 1 < lineManager.lineCount,
                  let operation = service.joinOperation(atRow: firstRow) {
                joinsRemaining -= 1
                guard shouldChangeText(in: operation.range, replacementText: operation.replacement) else {
                    break
                }
                replaceText(in: operation.range,
                           with: operation.replacement,
                           undoActionName: L10n.Undo.ActionName.joinLines,
                           updateSelection: false)
                joinsDone += 1
                caretColumn = operation.caretLocation - lineManager.line(atRow: firstRow).location
            }
            if joinsDone > 0 {
                caretTargets.append((row: firstRow, column: caretColumn))
                rowShift += joinsDone
            }
        }
        timedUndoManager.endUndoGrouping()
        guard !caretTargets.isEmpty else { return }

        let newSelections = caretTargets
            .compactMap { location(forRow: $0.row, column: $0.column) }
            .map { NSRange(location: min($0, string.length), length: 0) }
            .sorted { $0.location < $1.location }
        guard !newSelections.isEmpty else { return }
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        if newSelections.count == 1 {
            selection = newSelections[0]
            selectionAnchor = newSelections[0].location
        } else {
            applySelectedRanges(MultiSelectionController.normalize(newSelections))
        }
    }
}

// MARK: - Surround with / reindent
extension TextInputView {
    func surroundSelection(with template: SurroundTemplate) {
        guard let range = selection else { return }
        let selectedText = string.substring(with: NSRange(location: range.location, length: range.length))
        let anchorLine = lineManager.line(containingCharacterAt: range.location) ?? lineManager.line(atRow: 0)
        let anchorLineText = string.substring(with: NSRange(location: anchorLine.location, length: anchorLine.data.length))
        let indent = String(anchorLineText.prefix { $0 == " " || $0 == "\t" })
        let softTab = indentStrategy.string(indentLevel: 1)

        let nodes = SnippetParser().parse(template.body)
        let context = SnippetExpansionContext(selectedText: selectedText, softTab: softTab)
        let expansion = SnippetExpander(nodes: nodes, context: context).expand()

        let expandedLines = expansion.text.components(separatedBy: "\n")
        let reindented = expandedLines.enumerated()
            .map { index, line in index == 0 || line.isEmpty ? line : indent + line }
            .joined(separator: "\n")

        guard shouldChangeText(in: range, replacementText: reindented) else { return }
        timedUndoManager.endUndoGrouping()
        timedUndoManager.beginUndoGrouping()
        snippetSession = nil
        replaceText(in: range, with: reindented, undoActionName: L10n.Undo.ActionName.surroundWith)
        beginSnippetSession(
            expansion: expansion,
            origin: range.location,
            extraIndentPerNewline: (indent as NSString).length
        )
        timedUndoManager.endUndoGrouping()
    }

    func insertSnippet(_ expansion: SnippetExpansion, replacing range: NSRange, extraIndentPerNewline: Int = 0) {
        let text = expansion.text
        guard shouldChangeText(in: range, replacementText: text) else {
            return
        }
        snippetSession = nil
        replaceText(in: range, with: text, undoActionName: L10n.Undo.ActionName.typing)
        beginSnippetSession(expansion: expansion, origin: range.location, extraIndentPerNewline: extraIndentPerNewline)
    }

    var hasActiveSnippetSession: Bool {
        snippetSession?.isActive ?? false
    }

    @discardableResult
    func advanceSnippetSession() -> Bool {
        guard var session = snippetSession else {
            return false
        }
        applySnippetStep(session.advance())
        snippetSession = session.isActive ? session : nil
        return true
    }

    @discardableResult
    func retreatSnippetSession() -> Bool {
        guard var session = snippetSession, session.isActive else {
            return false
        }
        applySnippetStep(session.retreat())
        snippetSession = session
        return true
    }

    func cancelSnippetSession() {
        snippetSession = nil
    }

    func beginSnippetSession(expansion: SnippetExpansion, origin: Int, extraIndentPerNewline: Int = 0) {
        if let session = SnippetSession(
            expansion: expansion,
            origin: origin,
            extraIndentPerNewline: extraIndentPerNewline
        ) {
            snippetSession = session
            applySnippetStep(session.currentStep())
            return
        }
        let caretOffset: Int
        if let finalCursorOffset = expansion.finalCursorOffset {
            caretOffset = SnippetSession.mappedOffset(
                finalCursorOffset,
                in: expansion.text,
                extraIndentPerNewline: extraIndentPerNewline
            )
        } else {
            caretOffset = SnippetSession.mappedOffset(
                (expansion.text as NSString).length,
                in: expansion.text,
                extraIndentPerNewline: extraIndentPerNewline
            )
        }
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        isApplyingSnippetSelection = true
        selection = NSRange(location: min(origin + caretOffset, string.length), length: 0)
        selectionAnchor = selection?.location
        isApplyingSnippetSelection = false
    }

    private func applySnippetStep(_ step: SnippetSessionStep) {
        notifyInputDelegateAboutSelectionChangeInLayoutSubviews = true
        isApplyingSnippetSelection = true
        switch step {
        case .select(let ranges):
            if ranges.count == 1 {
                selection = ranges[0]
                selectionAnchor = ranges[0].location
            } else if !ranges.isEmpty {
                applySelectedRanges(MultiSelectionController.normalize(ranges), notifyDelegate: true)
            }
        case .finished(let caret):
            snippetSession = nil
            selection = NSRange(location: min(caret, string.length), length: 0)
            selectionAnchor = selection?.location
        }
        isApplyingSnippetSelection = false
    }

    private func invalidateSnippetSessionIfSelectionLeftStops(_ ranges: [NSRange]) {
        guard let session = snippetSession, session.isActive else {
            return
        }
        let stops = session.currentRanges
        guard !stops.isEmpty else {
            snippetSession = nil
            return
        }
        let stillInside = ranges.allSatisfy { range in
            stops.contains { stop in
                range.location >= stop.location && range.location <= stop.location + stop.length
            }
        }
        if !stillInside {
            snippetSession = nil
        }
    }

    /// Bracket-depth reindent of the selected lines. A deliberately small non-LSP fallback:
    /// it derives each line's indent from the running `([{` / `)]}` nesting depth (quotes and
    /// comments are not tracked), so it helps C-family and JSON and leaves brace-free languages
    /// essentially untouched.
    func reindentSelectedLines() {
        guard let range = selection,
              let (startLine, endLine) = lineManager.startAndEndLine(in: range) else {
            return
        }
        let indentUnit = indentStrategy.string(indentLevel: 1)
        // Nesting depth at the start of `startLine`, from the document beginning.
        var depth = bracketDepth(in: NSRange(location: 0, length: startLine.location))
        var edits: [(range: NSRange, replacement: String)] = []
        var row = startLine.index
        let lastRow = endLine.index
        while row <= lastRow {
            let line = lineManager.line(atRow: row)
            let content = string.substring(with: NSRange(location: line.location, length: line.data.length))
            let trimmed = content.drop { $0 == " " || $0 == "\t" }
            let leadingCount = content.count - trimmed.count
            let closesFirst = trimmed.first.map { ")]}".contains($0) } ?? false
            let effectiveDepth = max(0, closesFirst ? depth - 1 : depth)
            let desiredIndent = trimmed.isEmpty ? "" : String(repeating: indentUnit, count: effectiveDepth)
            if String(content.prefix(leadingCount)) != desiredIndent {
                edits.append((NSRange(location: line.location, length: leadingCount), desiredIndent))
            }
            depth = max(0, depth + bracketDelta(in: String(trimmed)))
            row += 1
        }
        guard !edits.isEmpty else { return }
        timedUndoManager.endUndoGrouping()
        timedUndoManager.beginUndoGrouping()
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            replaceText(in: edit.range, with: edit.replacement, undoActionName: L10n.Undo.ActionName.typing, updateSelection: false)
        }
        timedUndoManager.endUndoGrouping()
        setNeedsLayout()
    }

    private func bracketDepth(in range: NSRange) -> Int {
        max(0, bracketDelta(in: string.substring(with: range)))
    }

    private func bracketDelta(in text: String) -> Int {
        var delta = 0
        for character in text {
            if "([{".contains(character) {
                delta += 1
            } else if ")]}".contains(character) {
                delta -= 1
            }
        }
        return delta
    }
}
