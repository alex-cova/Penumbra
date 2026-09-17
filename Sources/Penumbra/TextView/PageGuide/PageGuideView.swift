import Foundation
@preconcurrency import AppKit

final class PageGuideView: UIView {
    var hairlineWidth: CGFloat {
        didSet {
            if hairlineWidth != oldValue {
                setNeedsLayout()
            }
        }
    }
    var hairlineColor: UIColor? {
        get {
            hairlineView.backgroundColor
        }
        set {
            hairlineView.backgroundColor = newValue
        }
    }
    var shadingColor: UIColor? {
        get {
            shadingView.backgroundColor
        }
        set {
            shadingView.backgroundColor = newValue
        }
    }

    var showReformattingGuideShading = true {
        didSet {
            if showReformattingGuideShading != oldValue {
                setNeedsDisplay()
            }
        }
    }

    private let hairlineView = UIView()
    private let shadingView = UIView()

    override init(frame: CGRect) {
        self.hairlineWidth = hairlineLength
        super.init(frame: frame)
        isUserInteractionEnabled = false
        hairlineView.isUserInteractionEnabled = false
        shadingView.isUserInteractionEnabled = false
        addSubview(shadingView)
        addSubview(hairlineView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hairlineView.frame = CGRect(x: 0, y: 0, width: hairlineWidth, height: bounds.height)
        if showReformattingGuideShading {
            shadingView.isHidden = false
            shadingView.frame = CGRect(x: hairlineWidth, y: 0, width: max(bounds.width - hairlineWidth, 0), height: bounds.height)
        } else {
            shadingView.isHidden = true
        }
    }
}
