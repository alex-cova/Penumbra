import Foundation
@preconcurrency import AppKit

protocol LineFragmentControllerDelegate: AnyObject {
    func string(in controller: LineFragmentController) -> String?
}

final class LineFragmentController {
    weak var delegate: LineFragmentControllerDelegate?
    var lineFragment: LineFragment {
        didSet {
            if lineFragment !== oldValue {
                renderer.lineFragment = lineFragment
                invalidateAttachedViewIfPresent()
            }
        }
    }
    weak var lineFragmentView: LineFragmentView? {
        didSet {
            let viewChanged = lineFragmentView !== oldValue
            let view = lineFragmentView
            let renderer = self.renderer
            MainActor.assumeIsolated {
                if viewChanged || view?.renderer !== renderer {
                    view?.renderer = renderer
                }
            }
        }
    }
    var markedRange: NSRange? {
        get {
            renderer.markedRange
        }
        set {
            if newValue != renderer.markedRange {
                renderer.markedRange = newValue
                invalidateAttachedViewIfPresent()
            }
        }
    }
    var markedTextBackgroundColor: UIColor {
        get {
            renderer.markedTextBackgroundColor
        }
        set {
            if newValue != renderer.markedTextBackgroundColor {
                renderer.markedTextBackgroundColor = newValue
                invalidateAttachedViewIfPresent()
            }
        }
    }
    var markedTextBackgroundCornerRadius: CGFloat {
        get {
            renderer.markedTextBackgroundCornerRadius
        }
        set {
            if newValue != renderer.markedTextBackgroundCornerRadius {
                renderer.markedTextBackgroundCornerRadius = newValue
                invalidateAttachedViewIfPresent()
            }
        }
    }
    var highlightedRangeFragments: [HighlightedRangeFragment] {
        get {
            renderer.highlightedRangeFragments
        }
        set {
            if newValue != renderer.highlightedRangeFragments {
                renderer.highlightedRangeFragments = newValue
                invalidateAttachedViewIfPresent()
            }
        }
    }
    var unfocusedAlpha: CGFloat {
        get {
            renderer.unfocusedAlpha
        }
        set {
            if newValue != renderer.unfocusedAlpha {
                renderer.unfocusedAlpha = newValue
                invalidateAttachedViewIfPresent()
            }
        }
    }
    var focusedRanges: [NSRange] {
        get {
            renderer.focusedRanges
        }
        set {
            if newValue != renderer.focusedRanges {
                renderer.focusedRanges = newValue
                invalidateAttachedViewIfPresent()
            }
        }
    }
    var foldPlaceholderText: String? {
        get {
            renderer.foldPlaceholderText
        }
        set {
            if newValue != renderer.foldPlaceholderText {
                renderer.foldPlaceholderText = newValue
                invalidateAttachedViewIfPresent()
            }
        }
    }
    var foldPlaceholderColor: UIColor {
        get {
            renderer.foldPlaceholderColor
        }
        set {
            if newValue != renderer.foldPlaceholderColor {
                renderer.foldPlaceholderColor = newValue
                invalidateAttachedViewIfPresent()
            }
        }
    }
    var foldPlaceholderBackgroundColor: UIColor {
        get {
            renderer.foldPlaceholderBackgroundColor
        }
        set {
            if newValue != renderer.foldPlaceholderBackgroundColor {
                renderer.foldPlaceholderBackgroundColor = newValue
                invalidateAttachedViewIfPresent()
            }
        }
    }

    private let renderer: LineFragmentRenderer

    private func invalidateAttachedViewIfPresent() {
        let view = lineFragmentView
        MainActor.assumeIsolated {
            view?.setNeedsDisplay()
        }
    }

    init(lineFragment: LineFragment, invisibleCharacterConfiguration: InvisibleCharacterConfiguration) {
        self.lineFragment = lineFragment
        self.renderer = LineFragmentRenderer(lineFragment: lineFragment, invisibleCharacterConfiguration: invisibleCharacterConfiguration)
        self.renderer.delegate = self
    }
}

// MARK: - LineFragmentRendererDelegate
extension LineFragmentController: LineFragmentRendererDelegate {
    func string(in lineFragmentRenderer: LineFragmentRenderer) -> String? {
        delegate?.string(in: self)
    }
}
