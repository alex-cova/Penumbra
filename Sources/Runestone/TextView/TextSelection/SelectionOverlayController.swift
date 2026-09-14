@preconcurrency import AppKit
import Foundation

@MainActor
final class SelectionOverlayController {
    private let textInputView: TextInputView
    private let caretRectService: CaretRectService
    private let selectionRectService: SelectionRectService
    private let caretView = CaretView()
    private var secondaryCaretViews: [CaretView] = []
    private let selectionOverlayView = SelectionOverlayView()
    private let startHandle = SelectionHandleView(kind: .start)
    private let endHandle = SelectionHandleView(kind: .end)
    private var blinkTimer: Timer?
    private var isCaretVisible = true
    private var isAdjustingSelection = false

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
        textInputView.addSubview(selectionOverlayView)
        textInputView.addSubview(caretView)
        textInputView.addSubview(startHandle)
        textInputView.addSubview(endHandle)
        updateColors()
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
        caretView.caretColor = textInputView.insertionPointColor
        secondaryCaretViews.forEach { $0.caretColor = textInputView.insertionPointColor.withAlphaComponent(0.85) }
        selectionOverlayView.highlightColor = textInputView.selectionHighlightColor
        startHandle.handleColor = textInputView.insertionPointColor
        endHandle.handleColor = textInputView.insertionPointColor
    }

    func selectionDidChange() {
        updateLayout()
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
        isCaretVisible = true
        caretView.isHidden = false
        secondaryCaretViews.forEach { $0.isHidden = false }
        startCaretBlinkIfNeeded()
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
        selectionOverlayView.selectionRects = highlightedRanges.flatMap { range in
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
        textInputView.bringSubviewToFront(startHandle)
        textInputView.bringSubviewToFront(endHandle)
    }

    private func updateCarets() {
        guard shouldShowCarets else {
            caretView.isHidden = true
            secondaryCaretViews.forEach { $0.isHidden = true }
            return
        }
        let ranges = caretRanges
        while secondaryCaretViews.count < max(ranges.count - 1, 0) {
            let caretView = CaretView()
            caretView.isUserInteractionEnabled = false
            textInputView.addSubview(caretView)
            secondaryCaretViews.append(caretView)
        }
        for (index, range) in ranges.enumerated() {
            let caretRect = caretRectService.caretRect(at: range.location, allowMovingCaretToNextLineFragment: true)
            let view = index == 0 ? caretView : secondaryCaretViews[index - 1]
            view.frame = caretRect
            view.isHidden = !isCaretVisible
            textInputView.bringSubviewToFront(view)
        }
        if ranges.count - 1 < secondaryCaretViews.count {
            for index in (ranges.count - 1)..<secondaryCaretViews.count {
                secondaryCaretViews[index].isHidden = true
            }
        }
    }

    private func updateCaretBlinkState() {
        if shouldShowCarets {
            startCaretBlinkIfNeeded()
        } else {
            stopCaretBlink()
        }
    }

    private func startCaretBlinkIfNeeded() {
        guard shouldShowCarets else {
            stopCaretBlink()
            return
        }
        guard blinkTimer == nil else {
            return
        }
        isCaretVisible = true
        caretView.isHidden = false
        secondaryCaretViews.forEach { $0.isHidden = false }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.toggleCaretVisibility()
            }
        }
    }

    private func stopCaretBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isCaretVisible = true
    }

    private func toggleCaretVisibility() {
        guard shouldShowCarets else {
            stopCaretBlink()
            return
        }
        isCaretVisible.toggle()
        caretView.isHidden = !isCaretVisible
        let visibleSecondaryCount = caretRanges.count > 0 ? max(caretRanges.count - 1, 0) : 0
        for index in 0..<visibleSecondaryCount where index < secondaryCaretViews.count {
            secondaryCaretViews[index].isHidden = !isCaretVisible
        }
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
