@preconcurrency import AppKit
import Foundation

/// Shows a hover preview of the lines hidden inside a collapsed fold region.
@MainActor
final class FoldPreviewController {
    weak var textInputView: TextInputView?
    weak var foldingModel: FoldingModel?
    weak var lineManager: LineManager?
    weak var stringView: StringView?

    private var hoverTask: Task<Void, Never>?
    private var previewPanel: NSPanel?
    private var previewTextView: NSTextView?
    private var hoveredRegionID: UUID?

    private let maxPreviewLines = 20
    private let hoverDelayNanoseconds: UInt64 = 300_000_000

    func mouseMoved(at pointInTextInput: CGPoint, placeholderRect: CGRect?, region: FoldRegion?) {
        hoverTask?.cancel()
        if let region, let placeholderRect, placeholderRect.contains(pointInTextInput), region.isCollapsed {
            hoveredRegionID = region.id
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.hoverDelayNanoseconds ?? 300_000_000)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    self?.showPreview(for: region)
                }
            }
        } else {
            hoveredRegionID = nil
            hidePreview()
        }
    }

    func dismiss() {
        hoverTask?.cancel()
        hoveredRegionID = nil
        hidePreview()
    }

    private func showPreview(for region: FoldRegion) {
        guard let hiddenLineRange = region.hiddenLineRange,
              let lineManager,
              let stringView,
              let textInputView else {
            return
        }
        let startRow = hiddenLineRange.lowerBound
        let endRow = min(hiddenLineRange.upperBound, startRow + maxPreviewLines - 1)
        guard startRow < lineManager.lineCount else {
            return
        }
        let startLocation = lineManager.location(ofRow: startRow)
        let endLocation = lineManager.contentRange(atRow: endRow).upperBound
        guard endLocation > startLocation else {
            return
        }
        var previewText = stringView.substring(in: NSRange(location: startLocation, length: endLocation - startLocation)) ?? ""
        if hiddenLineRange.upperBound > endRow {
            previewText += "\n…"
        }

        let panel = previewPanel ?? makePanel()
        previewPanel = panel
        previewTextView?.string = previewText
        previewTextView?.sizeToFit()

        let padding: CGFloat = 10
        let width = min(640, max(240, (previewTextView?.bounds.width ?? 200) + padding * 2))
        let height = min(360, (previewTextView?.bounds.height ?? 120) + padding * 2)
        let origin = textInputView.convert(
            NSPoint(x: 0, y: 0),
            to: nil
        )
        panel.setFrame(
            NSRect(x: origin.x + 24, y: origin.y - height - 8, width: width, height: height),
            display: true
        )
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func hidePreview() {
        previewPanel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
        panel.hasShadow = true
        panel.isOpaque = false

        let scrollView = NSScrollView(frame: panel.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.documentView = textView
        panel.contentView?.addSubview(scrollView)
        previewTextView = textView
        return panel
    }
}
