import Foundation
@preconcurrency import AppKit

final class CaretRectService {
    var stringView: StringView
    var lineManager: LineManager
    var textContainerInset: UIEdgeInsets = .zero
    var showLineNumbers = false
    weak var foldingController: FoldingController?

    private let lineControllerStorage: LineControllerStorage
    private let gutterWidthService: GutterWidthService
    private var leadingLineSpacing: CGFloat {
        if showLineNumbers {
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

    func caretRect(at location: Int, allowMovingCaretToNextLineFragment: Bool) -> CGRect {
        let adjustedLocation = foldingController?.visibleCaretLocation(for: location) ?? location
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
            let localCaretRect = lineController.caretRect(atIndex: lineLocalLocation)
            let globalYPosition = line.yPosition + localCaretRect.minY
            let globalRect = CGRect(x: localCaretRect.minX, y: globalYPosition, width: localCaretRect.width, height: localCaretRect.height)
            return globalRect.offsetBy(dx: leadingLineSpacing, dy: textContainerInset.top)
        }
    }
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
