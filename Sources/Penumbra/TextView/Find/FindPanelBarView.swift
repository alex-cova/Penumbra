import Foundation
@preconcurrency import AppKit

/// The find/replace bar's content. Every color comes from the active `Theme`'s `findBar*`
/// members (see `Theme.swift`) via `apply(theme:)`, so it always matches the host app's palette
/// instead of falling back to stock AppKit chrome — no bezeled/bordered system text fields,
/// titled `NSButton`s, or checkboxes.
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
            replaceFieldContainer.isHidden = mode == .find
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
    let replaceField = FindPanelTextField()
    private let findFieldContainer: FindPanelFieldContainer
    private let replaceFieldContainer: FindPanelFieldContainer
    private let matchLabel = NSTextField(labelWithString: "")
    private let previousButton = FindPanelIconButton(symbolName: "chevron.up", accessibilityLabel: "Previous Match")
    private let nextButton = FindPanelIconButton(symbolName: "chevron.down", accessibilityLabel: "Next Match")
    private let closeButton = FindPanelIconButton(symbolName: "xmark", accessibilityLabel: "Close")
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: ["Find", "Replace"], trackingMode: .selectOne, target: nil, action: nil)
    private let matchCaseButton = FindPanelToggleButton(title: "Aa", accessibilityLabel: "Match Case")
    private let regexButton = FindPanelToggleButton(title: ".*", accessibilityLabel: "Use Regular Expression")
    private let wrapAroundButton = FindPanelToggleButton(symbolName: "repeat", accessibilityLabel: "Wrap Around")
    private let hairlineView = NSView()
    private var theme: Theme = DefaultTheme()

    override init(frame frameRect: NSRect) {
        findFieldContainer = FindPanelFieldContainer(field: findField)
        replaceFieldContainer = FindPanelFieldContainer(field: replaceField)
        super.init(frame: frameRect)
        wantsLayer = true
        findField.placeholderString = "Find"
        replaceField.placeholderString = "Replace"
        findField.onReturn = { [weak self] shiftHeld in
            if shiftHeld {
                self?.onPrevious?()
            } else {
                self?.onNext?()
            }
        }
        findField.onEscape = { [weak self] in self?.onClose?() }
        replaceField.onEscape = { [weak self] in self?.onClose?() }
        matchLabel.font = .systemFont(ofSize: 11)
        [previousButton, nextButton, closeButton].forEach { $0.target = self }
        previousButton.action = #selector(previousClicked)
        nextButton.action = #selector(nextClicked)
        closeButton.action = #selector(closeClicked)
        [replaceButton, replaceAllButton].forEach { $0.bezelStyle = .rounded }
        modeControl.selectedSegment = 0
        wrapAroundButton.state = .on
        [hairlineView, findFieldContainer, replaceFieldContainer, matchLabel, modeControl,
         matchCaseButton, wrapAroundButton, regexButton,
         previousButton, nextButton, replaceButton, replaceAllButton, closeButton].forEach(addSubview)
        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked)
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked)
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
        replaceFieldContainer.isHidden = true
        replaceButton.isHidden = true
        replaceAllButton.isHidden = true
        apply(theme: theme)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Applies every `findBar*` color from `theme` — background, hairline, field chrome, text,
    /// and the toggle pills' accent — so the bar matches the host app instead of a fixed system
    /// look. Called once at init and again whenever `TextView.theme` is reassigned.
    func apply(theme: Theme) {
        self.theme = theme
        layer?.backgroundColor = theme.findBarBackgroundColor.cgColor
        hairlineView.layer?.backgroundColor = theme.findBarHairlineColor.cgColor
        [findFieldContainer, replaceFieldContainer].forEach {
            $0.apply(
                backgroundColor: theme.findBarFieldBackgroundColor,
                borderColor: theme.findBarFieldBorderColor,
                accentColor: theme.findBarAccentColor,
                textColor: theme.findBarTextColor,
                placeholderColor: theme.findBarMutedTextColor
            )
        }
        matchLabel.textColor = theme.findBarMutedTextColor
        [previousButton, nextButton, closeButton].forEach { $0.tintColor = theme.findBarMutedTextColor }
        [matchCaseButton, wrapAroundButton, regexButton].forEach {
            $0.accentColor = theme.findBarAccentColor
            $0.mutedColor = theme.findBarMutedTextColor
        }
        [replaceButton, replaceAllButton].forEach { $0.contentTintColor = theme.findBarTextColor }
    }

    /// `layer?.backgroundColor` above is baked to `CGColor` once, so a dynamic
    /// (appearance-adaptive) color goes stale if the effective appearance changes afterward.
    /// Re-bake every themed layer color whenever that happens.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(theme: theme)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: mode == .replace ? 78 : 52)
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 10
        let spacing: CGFloat = 8
        let rowHeight: CGFloat = 24
        hairlineView.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)

        let topRowY = bounds.height - rowHeight - padding
        var x = padding
        modeControl.frame = CGRect(x: x, y: topRowY + 1, width: 108, height: rowHeight - 2)
        x = modeControl.frame.maxX + spacing

        // Trailing cluster (toggle pills + close) is right-aligned so the find field can grow
        // between the mode control and the nav buttons.
        let toggleWidth: CGFloat = 32
        let toggleSpacing: CGFloat = 4
        let trailingClusterWidth = toggleWidth * 3 + toggleSpacing * 2 + spacing + (rowHeight - 2)
        let trailingX = bounds.width - padding - trailingClusterWidth
        let navButtonWidth = rowHeight - 2
        let navClusterWidth = 50 + spacing + navButtonWidth + 4 + navButtonWidth
        let findFieldWidth = max(280, trailingX - spacing - navClusterWidth - x)
        findFieldContainer.frame = CGRect(x: x, y: topRowY, width: findFieldWidth, height: rowHeight)
        x = findFieldContainer.frame.maxX + spacing
        matchLabel.frame = CGRect(x: x, y: topRowY + 4, width: 50, height: 16)
        x = matchLabel.frame.maxX + spacing
        previousButton.frame = CGRect(x: x, y: topRowY + 1, width: navButtonWidth, height: navButtonWidth)
        x = previousButton.frame.maxX + 4
        nextButton.frame = CGRect(x: x, y: topRowY + 1, width: navButtonWidth, height: navButtonWidth)

        var trailingClusterX = trailingX
        matchCaseButton.frame = CGRect(x: trailingClusterX, y: topRowY + 1, width: toggleWidth, height: rowHeight - 2)
        trailingClusterX = matchCaseButton.frame.maxX + toggleSpacing
        regexButton.frame = CGRect(x: trailingClusterX, y: topRowY + 1, width: toggleWidth, height: rowHeight - 2)
        trailingClusterX = regexButton.frame.maxX + toggleSpacing
        wrapAroundButton.frame = CGRect(x: trailingClusterX, y: topRowY + 1, width: toggleWidth, height: rowHeight - 2)
        trailingClusterX = wrapAroundButton.frame.maxX + spacing
        closeButton.frame = CGRect(x: trailingClusterX, y: topRowY + 1, width: navButtonWidth, height: navButtonWidth)

        if mode == .replace {
            let secondRowY = topRowY - spacing - rowHeight
            let replaceFieldX = modeControl.frame.minX + modeControl.frame.width + spacing
            let replaceFieldWidth = max(280, bounds.width - padding - replaceFieldX)
            replaceFieldContainer.frame = CGRect(x: replaceFieldX,
                                                 y: secondRowY,
                                                 width: replaceFieldWidth,
                                                 height: rowHeight)
            var replaceX = replaceFieldContainer.frame.maxX + spacing
            replaceButton.frame = CGRect(x: replaceX, y: secondRowY, width: 70, height: rowHeight)
            replaceX = replaceButton.frame.maxX + spacing
            replaceAllButton.frame = CGRect(x: replaceX, y: secondRowY, width: 50, height: rowHeight)
        }
    }

    func focusFindField(selecting selection: String? = nil) {
        if let selection, !selection.isEmpty {
            findField.stringValue = selection
        }
        onFindTextChanged?(findField.stringValue)
        // Defer first-responder so a host/menu handler that runs after opening the panel
        // (or the key event that triggered it) cannot steal focus back to the editor.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.findField)
            if let selection, !selection.isEmpty {
                self.findField.currentEditor()?.selectedRange = NSRange(location: 0, length: selection.utf16.count)
            } else if !self.findField.stringValue.isEmpty {
                self.findField.currentEditor()?.selectAll(nil)
            }
        }
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
}

/// A borderless text field inside a token-colored, rounded container — the replacement for a
/// system bezeled/bordered `NSTextField`. Its border brightens to the theme's accent color while
/// the field is focused, tracked via first-responder notifications.
private final class FindPanelFieldContainer: NSView {
    private let field: NSTextField
    private var isFocused = false
    private var borderColor: NSColor = .separatorColor
    private var accentColor: NSColor = .controlAccentColor

    init(field: NSTextField) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        addSubview(field)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didBeginEditing),
                                               name: NSControl.textDidBeginEditingNotification,
                                               object: field)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didEndEditing),
                                               name: NSControl.textDidEndEditingNotification,
                                               object: field)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        // While hidden (e.g. the replace field in `.find` mode) this container is never given an
        // explicit frame and stays at its `.zero` initial size — insetting that would hand the
        // field a negative-size frame, which AppKit's geometry validation flags as invalid.
        guard bounds.width > 16, bounds.height > 6 else {
            field.frame = .zero
            return
        }
        field.frame = bounds.insetBy(dx: 8, dy: 3)
    }

    func apply(backgroundColor: NSColor, borderColor: NSColor, accentColor: NSColor, textColor: NSColor, placeholderColor: NSColor) {
        self.borderColor = borderColor
        self.accentColor = accentColor
        layer?.backgroundColor = backgroundColor.cgColor
        field.textColor = textColor
        if let placeholder = field.placeholderString {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: placeholderColor, .font: field.font ?? .systemFont(ofSize: 12)]
            )
        }
        updateBorder()
    }

    @objc private func didBeginEditing() {
        isFocused = true
        updateBorder()
    }

    @objc private func didEndEditing() {
        isFocused = false
        updateBorder()
    }

    private func updateBorder() {
        layer?.borderColor = (isFocused ? accentColor : borderColor).cgColor
    }
}

/// A compact, icon-only action button (previous/next/close) with no bezel — SF Symbol content
/// tinted by ``tintColor`` instead of a titled system button.
private final class FindPanelIconButton: NSButton {
    var tintColor: NSColor = .secondaryLabelColor {
        didSet { contentTintColor = tintColor }
    }

    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(symbolConfiguration)
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
        contentTintColor = tintColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A small pill toggle (Case/Regex/Wrap Around) using AppKit's `.inline` bezel — the same native
/// style macOS uses for exactly this "search option chip" pattern — tinted by ``accentColor``
/// while on and ``mutedColor`` while off, instead of a titled checkbox.
private final class FindPanelToggleButton: NSButton {
    var accentColor: NSColor = .controlAccentColor {
        didSet { updateAppearance() }
    }
    var mutedColor: NSColor = .secondaryLabelColor {
        didSet { updateAppearance() }
    }

    override var state: NSControl.StateValue {
        didSet { updateAppearance() }
    }

    init(title: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        self.title = title
        commonInit(accessibilityLabel: accessibilityLabel)
    }

    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(symbolConfiguration)
        commonInit(accessibilityLabel: accessibilityLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit(accessibilityLabel: String) {
        setButtonType(.pushOnPushOff)
        bezelStyle = .inline
        font = .systemFont(ofSize: 11, weight: .medium)
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
        updateAppearance()
    }

    private func updateAppearance() {
        contentTintColor = state == .on ? accentColor : mutedColor
    }
}

final class FindPanelTextField: NSTextField {
    var onReturn: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?(event.modifierFlags.contains(.shift))
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
