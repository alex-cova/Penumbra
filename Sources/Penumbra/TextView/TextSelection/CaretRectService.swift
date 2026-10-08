import Foundation
@preconcurrency import AppKit

final class CaretRectService {
    var stringView: StringView
    var lineManager: LineManager
    var textContainerInset: NSEdgeInsets = .zero
    var showLineNumbers = false
    weak var foldingModel: FoldingModel?

    private let lineControllerStorage: LineControllerStorage
    private let gutterWidthService: GutterWidthService
    private var leadingLineSpacing: CGFloat {
        if gutterWidthService.reservesGutterSpace {
            return gutterWidthService.gutterWidth + textContainerInset.left
        } else {
            return textContainerInset.left
        }
    }

    init(stringView: StringView,
         lineManager: LineManager,
         lineControllerStorage: LineControllerStorage,
         gutterWidthService: GutterWidthService) {
        self.stringView = stringView
        self.lineManager = lineManager
        self.lineControllerStorage = lineControllerStorage
        self.gutterWidthService = gutterWidthService
    }

    /// With `beforeInlayHint`, a caret at an inlay hint's offset is in front of the hint's chip
    /// instead of behind it (the end of a selection that stops at the hint, the caret after ←).
    func caretRect(at location: Int, allowMovingCaretToNextLineFragment: Bool, beforeInlayHint: Bool = false) -> CGRect {
        let adjustedLocation = foldingModel?.visibleCaretLocation(for: location) ?? location
        let safeLocation = min(max(adjustedLocation, 0), stringView.length)
        guard let line = lineManager.line(containingCharacterAt: safeLocation) else {
            return CGRect(x: leadingLineSpacing, y: textContainerInset.top, width: 0, height: 0)
        }
        let lineController = lineControllerStorage.getOrCreateLineController(for: line)
        let lineLocalLocation = safeLocation - line.location
        if allowMovingCaretToNextLineFragment && shouldMoveCaretToNextLineFragment(forLocation: lineLocalLocation, in: line) {
            let rect = caretRect(at: location + 1, allowMovingCaretToNextLineFragment: false)
            return CGRect(x: leadingLineSpacing, y: rect.minY, width: rect.width, height: rect.height)
        } else {
            let localCaretRect = lineController.caretRect(atIndex: lineLocalLocation, beforeInlayHint: beforeInlayHint)
            let globalYPosition = line.yPosition + localCaretRect.minY
            let globalRect = CGRect(x: localCaretRect.minX, y: globalYPosition, width: localCaretRect.width, height: localCaretRect.height)
            return globalRect.offsetBy(dx: leadingLineSpacing, dy: textContainerInset.top)
        }
    }

    /// The caret's painted frame. ``caretRect(at:allowMovingCaretToNextLineFragment:)`` stays the
    /// thin bar so selection and popups do not move when the shape changes.
    ///
    /// With `beforeInlayHint`, a caret at an inlay hint's offset is drawn in front of the hint's chip
    /// instead of after it. The insertion point is the same either way.
    func caretPresentation(
        at location: Int,
        shape: CaretShape,
        allowMovingCaretToNextLineFragment: Bool,
        beforeInlayHint: Bool = false
    ) -> CaretPresentation {
        if shape == .bar {
            return CaretPresentation(frame: caretRect(
                at: location,
                allowMovingCaretToNextLineFragment: allowMovingCaretToNextLineFragment,
                beforeInlayHint: beforeInlayHint
            ))
        }
        let adjustedLocation = foldingModel?.visibleCaretLocation(for: location) ?? location
        let safeLocation = min(max(adjustedLocation, 0), stringView.length)
        guard let line = lineManager.line(containingCharacterAt: safeLocation) else {
            let frame = CGRect(x: leadingLineSpacing, y: textContainerInset.top, width: 0, height: 0)
            return CaretPresentation(frame: frame)
        }
        let lineController = lineControllerStorage.getOrCreateLineController(for: line)
        let lineLocalLocation = safeLocation - line.location
        if allowMovingCaretToNextLineFragment && shouldMoveCaretToNextLineFragment(forLocation: lineLocalLocation, in: line) {
            var presentation = caretPresentation(at: location + 1, shape: shape, allowMovingCaretToNextLineFragment: false)
            presentation.frame.origin.x = leadingLineSpacing
            return presentation
        }
        let metrics = lineController.caretMetrics(atIndex: lineLocalLocation, beforeInlayHint: beforeInlayHint)
        let globalBar = metrics.barRect.offsetBy(dx: leadingLineSpacing, dy: line.yPosition + textContainerInset.top)
        let width = max(metrics.advance, 1)
        let frame: CGRect
        switch shape {
        case .bar:
            frame = globalBar
        case .block:
            frame = CGRect(x: globalBar.minX, y: globalBar.minY, width: width, height: globalBar.height)
        case .underline:
            let thickness = min(Caret.width, globalBar.height)
            var y = globalBar.maxY - metrics.descent
            if y + thickness > globalBar.maxY {
                y = globalBar.maxY - thickness
            }
            if y < globalBar.minY {
                y = globalBar.minY
            }
            frame = CGRect(x: globalBar.minX, y: y, width: width, height: thickness)
        }
        return CaretPresentation(
            frame: frame,
            coveredText: shape == .block ? metrics.coveredText : "",
            coveredFont: metrics.coveredFont,
            descent: metrics.descent
        )
    }
}

struct CaretPresentation {
    var frame: CGRect
    var coveredText = ""
    var coveredFont: NSFont?
    var descent: CGFloat = 0
}

private extension CaretRectService {
    private func shouldMoveCaretToNextLineFragment(forLocation location: Int, in line: DocumentLineNode) -> Bool {
        let lineController = lineControllerStorage.getOrCreateLineController(for: line)
        guard lineController.numberOfLineFragments > 0 else {
            return false
        }
        guard let lineFragmentNode = lineController.lineFragmentNode(containingCharacterAt: location) else {
            return false
        }
        guard lineFragmentNode.index > 0 else {
            return false
        }
        return location == lineFragmentNode.data.lineFragment?.range.location
    }
}
