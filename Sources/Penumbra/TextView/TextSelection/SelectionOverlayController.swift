@preconcurrency import AppKit
import Foundation

@MainActor
final class SelectionOverlayController {
    private let textInputView: TextInputView
    private let caretRectService: CaretRectService
    private let selectionRectService: SelectionRectService
    private let caretView = CaretView()
    private var secondaryCaretViews: [CaretView] = []
    private let overlayHostView = SelectionChromeHostView()
    private let selectionOverlayView = SelectionOverlayView()
    private let startHandle = SelectionHandleView(kind: .start)
    private let endHandle = SelectionHandleView(kind: .end)
    private var isAdjustingSelection = false
    /// Set when the selection moved or text was edited, so the next ``updateCarets()`` shows the
    /// carets solid again for a blink interval instead of leaving them in whatever phase they were.
    private var needsBlinkRestart = true
    /// Frames of the carets placed by the last ``updateCarets()``, to tell a move from a re-layout.
    private var lastCaretFrames: [CGRect] = []
    /// Secondary caret views placed by the last ``updateCarets()``; the rest stay hidden.
    private var shownSecondaryCaretCount = 0

    var selectionRects: [TextSelectionRect] {
        selectionOverlayView.selectionRects
    }

    var isEnabled = false {
        didSet {
            if isEnabled != oldValue {
                updateVisibility()
                if isEnabled {
                    updateLayout()
                } else {
                    stopCaretBlink()
                }
            }
        }
    }

    init(textInputView: TextInputView,
         caretRectService: CaretRectService,
         selectionRectService: SelectionRectService) {
        self.textInputView = textInputView
        self.caretRectService = caretRectService
        self.selectionRectService = selectionRectService
        configureHandles()
    }

    func install() {
        textInputView.addSubview(overlayHostView)
        overlayHostView.addSubview(selectionOverlayView)
        overlayHostView.addSubview(caretView)
        overlayHostView.addSubview(startHandle)
        overlayHostView.addSubview(endHandle)
        updateColors()
    }

    /// The Metal canvas is a fixed overlay above the clip view. Move selection/caret chrome into a
    /// second fixed overlay so an opaque canvas cannot cover it; a viewport-origin `bounds` keeps
    /// the existing content-space caret and selection frames valid while scrolling.
    func setPresentationHost(_ parent: EditorView?, viewport: CGRect) {
        if let parent {
            if overlayHostView.superview !== parent {
                overlayHostView.removeFromSuperview()
                if let scrollView = parent as? EditorScrollView {
                    scrollView.addFixedOverlaySubview(overlayHostView)
                } else {
                    parent.addSubview(overlayHostView)
                }
            }
            placeAboveMetalCanvas()
            overlayHostView.frame = CGRect(origin: .zero, size: viewport.size)
            overlayHostView.bounds = viewport
        } else {
            if overlayHostView.superview !== textInputView {
                overlayHostView.removeFromSuperview()
                textInputView.addSubview(overlayHostView)
            }
            overlayHostView.frame = textInputView.bounds
            overlayHostView.bounds = CGRect(origin: .zero, size: textInputView.bounds.size)
        }
    }

    /// The opaque Metal canvas is a sibling overlay. Keep caret/selection chrome immediately above
    /// it — never absolute-front, so gutter/minimap/find stay clickable, and never below it.
    func placeAboveMetalCanvas() {
        guard let parent = overlayHostView.superview else {
            return
        }
        guard let canvas = parent.subviews.first(where: { $0 is MetalTextCanvasView }) else {
            return
        }
        if let scrollView = parent as? EditorScrollView {
            scrollView.insertFixedOverlaySubview(overlayHostView, positioned: .above, relativeTo: canvas)
        } else {
            parent.addSubview(overlayHostView, positioned: .above, relativeTo: canvas)
        }
    }

    func updateLayout() {
        guard isEnabled else {
            return
        }
        selectionOverlayView.frame = textInputView.bounds
        updateColors()
        updateSelectionOverlay()
        updateSelectionHandles()
        updateCarets()
        updateCaretBlinkState()
    }

    func updateColors() {
        let color = textInputView.insertionPointColor
        // A block caret is opaque so the glyph knocked out of it stays solid. A second bar
        // is dimmed so the primary one stays obvious.
        let secondary = textInputView.caretShape == .block ? color : color.withAlphaComponent(0.85)
        caretView.caretColor = color
        secondaryCaretViews.forEach { $0.caretColor = secondary }
        selectionOverlayView.highlightColor = textInputView.selectionHighlightColor
        startHandle.handleColor = color
        endHandle.handleColor = color
    }

    func selectionDidChange() {
        needsBlinkRestart = true
        updateLayout()
    }

    /// Blink or movement settings changed; applies them to the carets already on screen.
    func caretAnimationSettingsDidChange() {
        needsBlinkRestart = true
        guard isEnabled else {
            return
        }
        updateCaretBlinkState()
    }

    func editingDidChange(isEditing: Bool) {
        if isEditing {
            updateLayout()
        } else {
            stopCaretBlink()
            caretView.isHidden = true
            secondaryCaretViews.forEach { $0.isHidden = true }
            selectionOverlayView.selectionRects = []
            selectionOverlayView.setNeedsDisplay()
            startHandle.isHidden = true
            endHandle.isHidden = true
        }
    }

    func enableCursorBlinks() {
        guard isEnabled else {
            return
        }
        caretView.isHidden = false
        for index in 0..<min(shownSecondaryCaretCount, secondaryCaretViews.count) {
            secondaryCaretViews[index].isHidden = false
        }
        needsBlinkRestart = true
        updateCaretBlinkState()
    }
}

private extension SelectionOverlayController {
    private var caretRanges: [NSRange] {
        let ranges = textInputView.selectedRanges.filter { $0.length == 0 }
        if ranges.isEmpty, let selection = textInputView.selection, selection.length == 0 {
            return [selection]
        }
        return ranges
    }

    private var highlightedRanges: [NSRange] {
        textInputView.selectedRanges.filter { $0.length > 0 }
    }

    /// `ranges` that touch the laid-out rows. `updateLayout()` runs on every layout pass, and
    /// Select All Occurrences can leave tens of thousands of ranges: measuring each one would lay
    /// out its line on every scroll frame. The first range is always kept (the primary caret).
    private func rangesNearViewport(_ ranges: [NSRange]) -> [NSRange] {
        guard ranges.count > 1, let visibleRange = textInputView.laidOutCharacterRange else {
            return ranges
        }
        return ranges.enumerated().compactMap { index, range in
            let touches = range.location <= visibleRange.upperBound && range.upperBound >= visibleRange.location
            return index == 0 || touches ? range : nil
        }
    }

    private var shouldShowCarets: Bool {
        isEnabled
            && textInputView.isEditing
            && !caretRanges.isEmpty
            && textInputView.markedTextRange == nil
            && !isAdjustingSelection
    }

    private var shouldShowSelection: Bool {
        isEnabled && !highlightedRanges.isEmpty
    }

    private var shouldShowSelectionHandles: Bool {
        shouldShowSelection
            && highlightedRanges.count == 1
            && (textInputView.delegate?.textInputViewIsSelectable(textInputView) ?? true)
    }

    private func configureHandles() {
        startHandle.onDrag = { [weak self] event in
            self?.handleStartDrag(with: event)
        }
        startHandle.onDragEnded = { [weak self] event in
            self?.handleDragEnded(with: event)
        }
        endHandle.onDrag = { [weak self] event in
            self?.handleEndDrag(with: event)
        }
        endHandle.onDragEnded = { [weak self] event in
            self?.handleDragEnded(with: event)
        }
    }

    private func updateVisibility() {
        caretView.isHidden = !isEnabled
        secondaryCaretViews.forEach { $0.isHidden = !isEnabled }
        selectionOverlayView.isHidden = !isEnabled
        startHandle.isHidden = !isEnabled
        endHandle.isHidden = !isEnabled
    }

    private func updateSelectionOverlay() {
        guard shouldShowSelection else {
            selectionOverlayView.selectionRects = []
            selectionOverlayView.setNeedsDisplay()
            return
        }
        selectionOverlayView.selectionRects = rangesNearViewport(highlightedRanges).flatMap { range in
            selectionRectService.selectionRects(in: range)
        }
    }

    private func updateSelectionHandles() {
        guard shouldShowSelectionHandles, let selectedRange = highlightedRanges.first else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        let startCaretRect = caretRectService.caretRect(at: selectedRange.location, allowMovingCaretToNextLineFragment: true)
        let endIndex = max(selectedRange.upperBound - 1, selectedRange.location)
        let endCaretRect = caretRectService.caretRect(at: endIndex, allowMovingCaretToNextLineFragment: false)
        startHandle.frame = startHandle.frame(anchoredTo: startCaretRect)
        endHandle.frame = endHandle.frame(anchoredTo: endCaretRect)
        startHandle.isHidden = false
        endHandle.isHidden = false
        overlayHostView.bringSubviewToFront(startHandle)
        overlayHostView.bringSubviewToFront(endHandle)
    }

    private func updateCarets() {
        guard shouldShowCarets else {
            caretView.isHidden = true
            secondaryCaretViews.forEach { $0.isHidden = true }
            shownSecondaryCaretCount = 0
            lastCaretFrames = []
            return
        }
        let ranges = rangesNearViewport(caretRanges)
        let previousShownCount = shownSecondaryCaretCount
        shownSecondaryCaretCount = max(ranges.count - 1, 0)
        while secondaryCaretViews.count < max(ranges.count - 1, 0) {
            let caretView = CaretView()
            caretView.isUserInteractionEnabled = false
            overlayHostView.addSubview(caretView)
            secondaryCaretViews.append(caretView)
        }
        var frames: [CGRect] = []
        frames.reserveCapacity(ranges.count)
        for (index, range) in ranges.enumerated() {
            let view = index == 0 ? caretView : secondaryCaretViews[index - 1]
            // Pooled secondary views are reassigned when the caret count changes, so they would
            // glide from an unrelated caret's place.
            let canGlide = !view.isHidden && (index == 0 || previousShownCount == shownSecondaryCaretCount)
            configureCaret(view, at: range.location, isPrimary: index == 0, animatesMove: canGlide)
            view.isHidden = false
            overlayHostView.bringSubviewToFront(view)
            frames.append(view.frame)
        }
        if ranges.count - 1 < secondaryCaretViews.count {
            for index in (ranges.count - 1)..<secondaryCaretViews.count {
                secondaryCaretViews[index].isHidden = true
                secondaryCaretViews[index].layer?.removeAllAnimations()
            }
        }
        if frames != lastCaretFrames {
            needsBlinkRestart = true
            lastCaretFrames = frames
        }
    }

    private func configureCaret(_ view: CaretView, at location: Int, isPrimary: Bool, animatesMove: Bool) {
        let shape = textInputView.caretShape
        let presentation = caretRectService.caretPresentation(
            at: location,
            shape: shape,
            allowMovingCaretToNextLineFragment: true,
            beforeInlayHint: isPrimary && textInputView.caretIsBeforeInlayHint
        )
        let color = textInputView.insertionPointColor
        view.shape = shape
        let previousPosition = view.layer.map { $0.presentation()?.position ?? $0.position }
        view.frame = presentation.frame
        if animatesMove, let layer = view.layer, let previousPosition {
            glide(layer, from: previousPosition)
        }
        view.coveredText = presentation.coveredText
        view.coveredFont = presentation.coveredFont
        view.baselineFromBottom = presentation.descent
        view.coveredTextColor = textInputView.backgroundColor ?? .textBackgroundColor
        view.caretColor = isPrimary || shape == .block ? color : color.withAlphaComponent(0.85)
    }

    /// Slides `layer` from where it was drawn to its new position. The model position is already
    /// the destination, so caret rects and popups anchored to it are never behind the animation.
    private func glide(_ layer: CALayer, from previousPosition: CGPoint) {
        guard textInputView.smoothCaretMovement, !Self.reduceMotion else {
            layer.removeAnimation(forKey: CaretAnimation.moveKey)
            return
        }
        let delta = CGPoint(x: previousPosition.x - layer.position.x, y: previousPosition.y - layer.position.y)
        let viewportHeight = max(textInputView.viewport.height, 1)
        guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5, abs(delta.y) <= viewportHeight else {
            return
        }
        let animation = CABasicAnimation(keyPath: "position")
        animation.isAdditive = true
        animation.fromValue = NSValue(point: delta)
        animation.toValue = NSValue(point: .zero)
        animation.duration = CaretAnimation.moveDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: CaretAnimation.moveKey)
    }

    private func updateCaretBlinkState() {
        guard shouldShowCarets else {
            stopCaretBlink()
            return
        }
        guard needsBlinkRestart else {
            return
        }
        needsBlinkRestart = false
        guard textInputView.caretBlinkingEnabled else {
            stopCaretBlink()
            return
        }
        let smooth = textInputView.smoothCaretBlinking && !Self.reduceMotion
        let animation = CaretAnimation.blink(interval: textInputView.caretBlinkInterval, smooth: smooth)
        for view in shownCaretViews {
            guard let layer = view.layer else { continue }
            // Restarting at "now" keeps the caret solid for the first half of the cycle.
            let restarted = animation.copy() as? CAKeyframeAnimation ?? animation
            restarted.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.removeAnimation(forKey: CaretAnimation.blinkKey)
            layer.add(restarted, forKey: CaretAnimation.blinkKey)
        }
    }

    private func stopCaretBlink() {
        needsBlinkRestart = true
        ([caretView] + secondaryCaretViews).forEach {
            $0.layer?.removeAnimation(forKey: CaretAnimation.blinkKey)
            $0.layer?.removeAnimation(forKey: CaretAnimation.moveKey)
        }
    }

    private var shownCaretViews: [CaretView] {
        [caretView] + secondaryCaretViews.prefix(shownSecondaryCaretCount)
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func handleStartDrag(with event: NSEvent) {
        guard let selection = textInputView.selection else {
            return
        }
        isAdjustingSelection = true
        stopCaretBlink()
        let point = textInputView.convert(event.locationInWindow, from: nil)
        if let index = textInputView.characterIndex(at: point) {
            textInputView.updateSelection(from: index, to: selection.upperBound)
        }
    }

    private func handleEndDrag(with event: NSEvent) {
        guard let selection = textInputView.selection else {
            return
        }
        isAdjustingSelection = true
        stopCaretBlink()
        let point = textInputView.convert(event.locationInWindow, from: nil)
        if let index = textInputView.characterIndex(at: point) {
            textInputView.updateSelection(from: selection.location, to: index)
        }
    }

    private func handleDragEnded(with event: NSEvent) {
        isAdjustingSelection = false
        textInputView.selectionAnchor = textInputView.selection?.location
        updateLayout()
    }
}

/// Layer-backed host so caret/selection chrome composite above `CAMetalLayer`. Empty space must
/// not eat hits — the Metal canvas already returns `nil` from `hitTest`, and text input lives
/// under the clip view.
private final class SelectionChromeHostView: EditorView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
