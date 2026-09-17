@preconcurrency import AppKit
import Foundation

final class CaretView: UIView {
    var caretColor: UIColor = .label {
        didSet {
            layer?.backgroundColor = caretColor.cgColor
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        isUserInteractionEnabled = false
        layer?.backgroundColor = caretColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = caretColor.cgColor
    }
}
