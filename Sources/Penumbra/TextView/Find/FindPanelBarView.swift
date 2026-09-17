import Foundation
@preconcurrency import AppKit

final class FindPanelBarView: NSView {
    var onFindTextChanged: ((String) -> Void)?
    var onReplaceTextChanged: ((String) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onClose: (() -> Void)?
    var onModeChanged: ((FindPanelMode) -> Void)?
    var onMatchCaseChanged: ((Bool) -> Void)?
    var onWrapAroundChanged: ((Bool) -> Void)?
    var onUsesRegularExpressionChanged: ((Bool) -> Void)?

    var mode: FindPanelMode = .find {
        didSet {
            replaceField.isHidden = mode == .find
            replaceButton.isHidden = mode == .find
            replaceAllButton.isHidden = mode == .find
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    var matchLabelText: String = "" {
        didSet {
            matchLabel.stringValue = matchLabelText
        }
    }

    var isMatchCaseEnabled: Bool {
        get { matchCaseButton.state == .on }
        set { matchCaseButton.state = newValue ? .on : .off }
    }

    var isWrapAroundEnabled: Bool {
        get { wrapAroundButton.state == .on }
        set { wrapAroundButton.state = newValue ? .on : .off }
    }

    var usesRegularExpression: Bool {
        get { regexButton.state == .on }
        set { regexButton.state = newValue ? .on : .off }
    }

    let findField = FindPanelTextField()
    let replaceField = NSTextField()
    private let matchLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)
    private let closeButton = NSButton(title: "Done", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: ["Find", "Replace"], trackingMode: .selectOne, target: nil, action: nil)
    private let matchCaseButton = NSButton(checkboxWithTitle: "Case", target: nil, action: nil)
    private let wrapAroundButton = NSButton(checkboxWithTitle: "Wrap", target: nil, action: nil)
    private let regexButton = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        configureField(findField, placeholder: "Find")
        configureField(replaceField, placeholder: "Replace")
        findField.onReturn = { [weak self] shiftHeld in
            if shiftHeld {
                self?.onPrevious?()
            } else {
                self?.onNext?()
            }
        }
        matchLabel.font = .systemFont(ofSize: 11)
        matchLabel.textColor = .secondaryLabelColor
        [previousButton, nextButton, replaceButton, replaceAllButton, closeButton].forEach {
            $0.bezelStyle = .rounded
        }
        modeControl.selectedSegment = 0
        wrapAroundButton.state = .on
        [findField, replaceField, matchLabel, modeControl, matchCaseButton, wrapAroundButton, regexButton,
         previousButton, nextButton, replaceButton, replaceAllButton, closeButton].forEach(addSubview)
        previousButton.target = self
        previousButton.action = #selector(previousClicked)
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked)
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        matchCaseButton.target = self
        matchCaseButton.action = #selector(matchCaseChanged)
        wrapAroundButton.target = self
        wrapAroundButton.action = #selector(wrapAroundChanged)
        regexButton.target = self
        regexButton.action = #selector(regexChanged)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(findFieldChanged),
                                               name: NSControl.textDidChangeNotification,
                                               object: findField)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(replaceFieldChanged),
                                               name: NSControl.textDidChangeNotification,
                                               object: replaceField)
        replaceField.isHidden = true
        replaceButton.isHidden = true
        replaceAllButton.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// `layer?.backgroundColor` above is baked to `CGColor` once, at init, so a dynamic
    /// (appearance-adaptive) system color like `.windowBackgroundColor` goes stale if the
    /// effective appearance changes afterward. Re-bake it whenever that happens.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: mode == .replace ? 78 : 52)
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 8
        let spacing: CGFloat = 6
        var x = padding
        modeControl.frame = CGRect(x: x, y: bounds.height - 22 - padding, width: 120, height: 22)
        x = modeControl.frame.maxX + spacing
        findField.frame = CGRect(x: x, y: bounds.height - 22 - padding, width: 180, height: 22)
        x = findField.frame.maxX + spacing
        if mode == .replace {
            replaceField.frame = CGRect(x: padding + 126, y: bounds.height - 22 - padding - 26, width: 180, height: 22)
        }
        matchLabel.frame = CGRect(x: x, y: bounds.height - 18 - padding, width: 80, height: 16)
        x = matchLabel.frame.maxX + spacing
        previousButton.frame = CGRect(x: x, y: bounds.height - 24 - padding, width: 72, height: 24)
        x = previousButton.frame.maxX + spacing
        nextButton.frame = CGRect(x: x, y: bounds.height - 24 - padding, width: 56, height: 24)
        x = nextButton.frame.maxX + spacing
        if mode == .replace {
            replaceButton.frame = CGRect(x: x, y: bounds.height - 24 - padding - 26, width: 72, height: 24)
            replaceAllButton.frame = CGRect(x: replaceButton.frame.maxX + spacing, y: replaceButton.frame.maxY, width: 48, height: 24)
        }
        closeButton.frame = CGRect(x: bounds.width - 56 - padding, y: bounds.height - 24 - padding, width: 56, height: 24)
        let optionsY = bounds.height - 22 - padding - 26
        matchCaseButton.frame = CGRect(x: padding, y: optionsY, width: 64, height: 18)
        wrapAroundButton.frame = CGRect(x: matchCaseButton.frame.maxX + spacing, y: optionsY, width: 64, height: 18)
        regexButton.frame = CGRect(x: wrapAroundButton.frame.maxX + spacing, y: optionsY, width: 72, height: 18)
    }

    func focusFindField(selecting selection: String? = nil) {
        window?.makeFirstResponder(findField)
        if let selection, !selection.isEmpty {
            findField.stringValue = selection
            findField.currentEditor()?.selectedRange = NSRange(location: 0, length: selection.utf16.count)
        }
        onFindTextChanged?(findField.stringValue)
    }

    func setMode(_ mode: FindPanelMode) {
        self.mode = mode
        modeControl.selectedSegment = mode == .find ? 0 : 1
    }

    var findText: String { findField.stringValue }
    var replaceText: String { replaceField.stringValue }

    @objc private func findFieldChanged() {
        onFindTextChanged?(findField.stringValue)
    }

    @objc private func replaceFieldChanged() {
        onReplaceTextChanged?(replaceField.stringValue)
    }

    @objc private func previousClicked() { onPrevious?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func replaceClicked() { onReplace?() }
    @objc private func replaceAllClicked() { onReplaceAll?() }
    @objc private func closeClicked() { onClose?() }

    @objc private func modeChanged() {
        mode = modeControl.selectedSegment == 0 ? .find : .replace
        onModeChanged?(mode)
    }

    @objc private func matchCaseChanged() {
        onMatchCaseChanged?(matchCaseButton.state == .on)
    }

    @objc private func wrapAroundChanged() {
        onWrapAroundChanged?(wrapAroundButton.state == .on)
    }

    @objc private func regexChanged() {
        onUsesRegularExpressionChanged?(regexButton.state == .on)
    }

    private func configureField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
    }
}

final class FindPanelTextField: NSTextField {
    var onReturn: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?(event.modifierFlags.contains(.shift))
            return
        }
        super.keyDown(with: event)
    }
}
