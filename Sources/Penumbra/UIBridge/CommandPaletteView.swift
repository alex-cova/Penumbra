@preconcurrency import AppKit

/// The overlay for Search Everywhere / Find Action / Recent Files / Go-to-file: an optional tab
/// strip, a query field above a grouped, keyboard-navigable results list, and a footer showing
/// the selected row's full path. Positioned and driven by `CommandPaletteController`; follows
/// the same `NSView` + baked-`CGColor` idiom as `WorkspaceSearchPanelView`.
@MainActor
public final class CommandPaletteView: NSView {
    public var onQueryChange: ((String) -> Void)?
    public var onMoveSelection: ((Int) -> Void)?
    public var onConfirm: (() -> Void)?
    /// ⇧↩ or the footer button: run the selected row's ``PaletteItem/alternateAction``.
    public var onConfirmAlternate: (() -> Void)?
    public var onCancel: (() -> Void)?
    /// Row was clicked — argument is the item index (headers excluded).
    public var onActivateItemAtIndex: ((Int) -> Void)?
    public var onSelectTab: ((PaletteTab) -> Void)?
    public var onToggleNonProjectItems: ((Bool) -> Void)?

    private enum Row {
        case header(String)
        case item(PaletteItem)
    }

    private let queryField = PaletteQueryField()
    private let searchIcon = NSImageView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let materialView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let tabStack = NSStackView()
    private let tabContainer = NSView()
    private let nonProjectToggle = NSButton(checkboxWithTitle: "Include non-project items", target: nil, action: nil)
    private let footerLabel = NSTextField(labelWithString: "")
    private let splitButton = NSButton(title: "Open In Right Split", target: nil, action: nil)
    private var tabHeight: NSLayoutConstraint?
    private var tabButtons: [(tab: PaletteTab, button: PaletteTabButton)] = []

    private var rows: [Row] = []
    /// Table row index for each item index.
    private var itemRowIndices: [Int] = []
    /// Item index for each table row (`-1` for headers).
    private var rowItemIndices: [Int] = []
    /// Table row index of the currently selected item, or `nil`.
    private var selectedTableRow: Int?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var placeholder: String = "" {
        didSet { queryField.placeholderString = placeholder }
    }

    /// Dim right-aligned hint inside the query field (e.g. the sigil cheat-sheet).
    public var hint: String = "" {
        didSet { hintLabel.stringValue = hint }
    }

    public var query: String {
        get { queryField.stringValue }
        set { queryField.stringValue = newValue }
    }

    /// Tabs to show. An empty list hides the strip.
    public var tabs: [PaletteTab] = [] {
        didSet { rebuildTabs() }
    }

    public var selectedTab: PaletteTab? {
        didSet { refreshTabSelection() }
    }

    public var showsNonProjectToggle = false {
        didSet { nonProjectToggle.isHidden = !showsNonProjectToggle }
    }

    public var includesNonProjectItems: Bool {
        get { nonProjectToggle.state == .on }
        set { nonProjectToggle.state = newValue ? .on : .off }
    }

    /// Makes the query field first responder — call after the view is in a window.
    public func focusQueryField() {
        window?.makeFirstResponder(queryField)
    }

    /// - Parameters:
    ///   - sections: grouped results.
    ///   - selectedItemIndex: index among items (headers excluded).
    public func update(sections: [PaletteSection], selectedItemIndex: Int) {
        var newRows: [Row] = []
        var itemRows: [Int] = []
        var rowItems: [Int] = []
        for section in sections {
            if !section.title.isEmpty {
                newRows.append(.header(section.title))
                rowItems.append(-1)
            }
            for item in section.items {
                itemRows.append(newRows.count)
                rowItems.append(itemRows.count - 1)
                newRows.append(.item(item))
            }
        }
        rows = newRows
        itemRowIndices = itemRows
        rowItemIndices = rowItems
        tableView.reloadData()
        applySelection(itemIndex: selectedItemIndex)
    }

    /// Moves the selection without rebuilding the rows — the arrow-key fast path.
    public func updateSelection(_ selectedItemIndex: Int) {
        applySelection(itemIndex: selectedItemIndex)
    }

    private func applySelection(itemIndex: Int) {
        if itemRowIndices.isEmpty {
            selectedTableRow = nil
            tableView.deselectAll(nil)
        } else {
            let clamped = min(max(itemIndex, 0), itemRowIndices.count - 1)
            let row = itemRowIndices[clamped]
            selectedTableRow = row
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            // Keep the section header visible when the first item of a section is selected.
            tableView.scrollRowToVisible(clamped == 0 ? 0 : row)
        }
        refreshFooter()
    }

    private func refreshFooter() {
        var item: PaletteItem?
        if let selectedTableRow, rows.indices.contains(selectedTableRow), case .item(let selected) = rows[selectedTableRow] {
            item = selected
        }
        footerLabel.stringValue = item?.footer ?? ""
        splitButton.isHidden = item?.alternateAction == nil
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
        refreshTabSelection()
    }

    // MARK: - Layout

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 24
        layer?.shadowOffset = .zero

        materialView.material = .hudWindow
        materialView.blendingMode = .withinWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 12
        materialView.layer?.cornerCurve = .continuous
        materialView.layer?.masksToBounds = true
        materialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(materialView)

        applyChromeColors()
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyChromeColors()
            }
        }

        // Tab strip.
        tabContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabContainer)
        tabStack.orientation = .horizontal
        tabStack.spacing = 4
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.addSubview(tabStack)
        nonProjectToggle.controlSize = .small
        nonProjectToggle.font = .systemFont(ofSize: 12)
        nonProjectToggle.target = self
        nonProjectToggle.action = #selector(nonProjectToggled)
        nonProjectToggle.isHidden = true
        nonProjectToggle.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.addSubview(nonProjectToggle)

        // Query row.
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .tertiaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchIcon)

        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.font = .systemFont(ofSize: 17, weight: .regular)
        queryField.isBezeled = false
        queryField.drawsBackground = false
        queryField.focusRingType = .none
        queryField.lineBreakMode = .byClipping
        queryField.delegate = self
        queryField.onMoveSelection = { [weak self] delta in self?.onMoveSelection?(delta) }
        queryField.onConfirm = { [weak self] in self?.onConfirm?() }
        queryField.onConfirmAlternate = { [weak self] in self?.onConfirmAlternate?() }
        queryField.onCancel = { [weak self] in self?.onCancel?() }
        queryField.onCycleTab = { [weak self] delta in self?.cycleTab(by: delta) ?? false }
        addSubview(queryField)

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .right
        hintLabel.lineBreakMode = .byTruncatingHead
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(hintLabel)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Results.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.floatsGroupRows = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.target = self
        tableView.action = #selector(tableViewClicked)
        scrollView.documentView = tableView

        // Footer.
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerSeparator)

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(footerLabel)

        splitButton.isBordered = false
        splitButton.font = .systemFont(ofSize: 11)
        splitButton.contentTintColor = .controlAccentColor
        splitButton.target = self
        splitButton.action = #selector(splitButtonClicked)
        splitButton.toolTip = "⇧↩"
        splitButton.isHidden = true
        splitButton.translatesAutoresizingMaskIntoConstraints = false
        splitButton.setContentHuggingPriority(.required, for: .horizontal)
        splitButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(splitButton)

        let tabHeight = tabContainer.heightAnchor.constraint(equalToConstant: 0)
        self.tabHeight = tabHeight

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tabContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tabContainer.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            tabHeight,
            tabStack.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            tabStack.centerYAnchor.constraint(equalTo: tabContainer.centerYAnchor),
            nonProjectToggle.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            nonProjectToggle.centerYAnchor.constraint(equalTo: tabContainer.centerYAnchor),

            searchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: queryField.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),

            queryField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            queryField.trailingAnchor.constraint(equalTo: hintLabel.leadingAnchor, constant: -8),
            queryField.topAnchor.constraint(equalTo: tabContainer.bottomAnchor, constant: 10),
            queryField.heightAnchor.constraint(equalToConstant: 28),

            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hintLabel.centerYAnchor.constraint(equalTo: queryField.centerYAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -4),

            footerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerSeparator.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -6),

            footerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: splitButton.leadingAnchor, constant: -12),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            splitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            splitButton.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor)
        ])
    }

    private func applyChromeColors() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        materialView.isHidden = reduceTransparency
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if reduceTransparency {
            if isDark {
                layer?.backgroundColor = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.133, alpha: 1).cgColor
            } else {
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            }
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        if isDark {
            layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: - Tabs

    private func rebuildTabs() {
        for (_, button) in tabButtons {
            tabStack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        tabButtons = tabs.map { tab in
            let button = PaletteTabButton(title: tab.title)
            button.target = self
            button.action = #selector(tabClicked(_:))
            tabStack.addArrangedSubview(button)
            return (tab, button)
        }
        tabContainer.isHidden = tabs.isEmpty
        tabHeight?.constant = tabs.isEmpty ? 0 : 28
        refreshTabSelection()
    }

    private func refreshTabSelection() {
        for (tab, button) in tabButtons {
            button.isSelectedTab = tab == selectedTab
        }
    }

    /// Tab / ⇧Tab. Returns `false` (leaving the key to the field) when there are no tabs.
    private func cycleTab(by delta: Int) -> Bool {
        guard tabs.count > 1, let selectedTab, let current = tabs.firstIndex(of: selectedTab) else { return false }
        let next = (current + delta + tabs.count) % tabs.count
        onSelectTab?(tabs[next])
        return true
    }

    @objc private func tabClicked(_ sender: PaletteTabButton) {
        guard let entry = tabButtons.first(where: { $0.button === sender }) else { return }
        onSelectTab?(entry.tab)
        focusQueryField()
    }

    @objc private func nonProjectToggled() {
        onToggleNonProjectItems?(includesNonProjectItems)
        focusQueryField()
    }

    @objc private func splitButtonClicked() {
        onConfirmAlternate?()
    }

    @objc private func tableViewClicked() {
        let clickedRow = tableView.clickedRow
        guard rowItemIndices.indices.contains(clickedRow), rowItemIndices[clickedRow] >= 0 else { return }
        onActivateItemAtIndex?(rowItemIndices[clickedRow])
    }

    // MARK: - Row content

    private static let titleFont = NSFont.systemFont(ofSize: 13)
    private static let boldTitleFont = NSFont.boldSystemFont(ofSize: 13)

    private func attributedTitle(for item: PaletteItem) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: item.title,
            attributes: [.foregroundColor: NSColor.labelColor, .font: Self.titleFont]
        )
        guard !item.matchedIndices.isEmpty else { return result }
        let matched = Set(item.matchedIndices)
        var utf16Offset = 0
        for (index, character) in item.title.enumerated() {
            let length = character.utf16.count
            if matched.contains(index) {
                result.addAttributes(
                    [.foregroundColor: NSColor.controlAccentColor, .font: Self.boldTitleFont],
                    range: NSRange(location: utf16Offset, length: length)
                )
            }
            utf16Offset += length
        }
        return result
    }

    fileprivate static func isKeyboardShortcut(_ subtitle: String) -> Bool {
        subtitle.contains("⌘")
            || subtitle.contains("⌃")
            || subtitle.contains("⌥")
            || subtitle.contains("⇧")
            || subtitle.contains("\u{2303}")
    }
}

extension CommandPaletteView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .header = rows[row] {
            let id = NSUserInterfaceItemIdentifier("headerRow")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? NSTableRowView ?? {
                let created = NSTableRowView()
                created.identifier = id
                created.selectionHighlightStyle = .none
                return created
            }()
            return view
        }
        let id = NSUserInterfaceItemIdentifier("itemRow")
        return tableView.makeView(withIdentifier: id, owner: self) as? PaletteRowView ?? {
            let created = PaletteRowView()
            created.identifier = id
            return created
        }()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("headerCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? Self.makeLabelCell(id: id)
            cell.textField?.stringValue = title
            cell.textField?.textColor = .tertiaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            return cell
        case .item(let item):
            let id = NSUserInterfaceItemIdentifier("itemCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? PaletteItemCell ?? PaletteItemCell(id: id)
            let shortcut = item.subtitle.flatMap { Self.isKeyboardShortcut($0) ? $0 : nil }
            let location = item.location ?? (shortcut == nil ? item.subtitle : nil)
            cell.apply(
                title: attributedTitle(for: item),
                icon: item.icon,
                location: location,
                trailing: item.trailing ?? shortcut,
                trailingIsShortcut: item.trailing == nil && shortcut != nil
            )
            return cell
        }
    }

    private static func makeLabelCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let view = NSTableCellView()
        view.identifier = id
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        view.addSubview(textField)
        view.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        return view
    }
}

extension CommandPaletteView: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(queryField.stringValue)
    }
}

/// Query field that routes ↑/↓/Return/⇧Return/Tab/Page keys/Esc to the palette instead of the
/// field editor.
private final class PaletteQueryField: NSTextField {
    var onMoveSelection: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onConfirmAlternate: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Returns whether it handled the key.
    var onCycleTab: ((Int) -> Bool)?

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            onMoveSelection?(-1)
        case #selector(NSResponder.moveDown(_:)):
            onMoveSelection?(1)
        case #selector(NSResponder.pageUp(_:)):
            onMoveSelection?(-10)
        case #selector(NSResponder.pageDown(_:)):
            onMoveSelection?(10)
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onConfirmAlternate?()
            } else {
                onConfirm?()
            }
        case #selector(NSResponder.insertTab(_:)):
            if onCycleTab?(1) != true { super.doCommand(by: selector) }
        case #selector(NSResponder.insertBacktab(_:)):
            if onCycleTab?(-1) != true { super.doCommand(by: selector) }
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            super.doCommand(by: selector)
        }
    }
}

private final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
    }
}

/// A pill-shaped tab button; the selected tab is filled with the accent colour.
private final class PaletteTabButton: NSButton {
    var isSelectedTab = false {
        didSet { applyStyle() }
    }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        font = .systemFont(ofSize: 12, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        refusesFirstResponder = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 16
        size.height = 24
        return size
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        let color: NSColor = isSelectedTab ? .labelColor : .secondaryLabelColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: color, .font: font ?? NSFont.systemFont(ofSize: 12)]
        )
        layer?.backgroundColor = isSelectedTab
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = isSelectedTab ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        setAccessibilityLabel(title)
        setAccessibilitySelected(isSelectedTab)
    }
}

private final class PaletteItemCell: NSTableCellView {
    private let iconView = NSImageView()
    private let locationField = NSTextField(labelWithString: "")
    private let trailingField = NSTextField(labelWithString: "")
    private var titleLeading: NSLayoutConstraint?

    private static var symbolCache: [String: NSImage] = [:]

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(textField)
        self.textField = textField

        locationField.translatesAutoresizingMaskIntoConstraints = false
        locationField.font = .systemFont(ofSize: 12)
        locationField.textColor = .secondaryLabelColor
        locationField.lineBreakMode = .byTruncatingTail
        locationField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(locationField)

        trailingField.translatesAutoresizingMaskIntoConstraints = false
        trailingField.alignment = .right
        trailingField.lineBreakMode = .byTruncatingHead
        trailingField.setContentHuggingPriority(.required, for: .horizontal)
        trailingField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(trailingField)

        let titleLeading = textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        self.titleLeading = titleLeading
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLeading,
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),

            locationField.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 6),
            locationField.centerYAnchor.constraint(equalTo: centerYAnchor),
            locationField.trailingAnchor.constraint(lessThanOrEqualTo: trailingField.leadingAnchor, constant: -10),

            trailingField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailingField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        title: NSAttributedString,
        icon: PaletteIcon?,
        location: String?,
        trailing: String?,
        trailingIsShortcut: Bool
    ) {
        textField?.attributedStringValue = title
        if let icon, let image = Self.symbol(named: icon.systemName) {
            iconView.image = image
            iconView.contentTintColor = Self.color(for: icon.tint)
            iconView.isHidden = false
            titleLeading?.constant = 34
        } else {
            iconView.image = nil
            iconView.isHidden = true
            titleLeading?.constant = 10
        }
        locationField.stringValue = location ?? ""
        locationField.isHidden = (location ?? "").isEmpty
        if let trailing, !trailing.isEmpty {
            trailingField.stringValue = trailing
            trailingField.font = trailingIsShortcut
                ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                : .systemFont(ofSize: 12)
            trailingField.textColor = trailingIsShortcut ? .tertiaryLabelColor : .secondaryLabelColor
            trailingField.isHidden = false
        } else {
            trailingField.stringValue = ""
            trailingField.isHidden = true
        }
    }

    private static func symbol(named name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        symbolCache[name] = image
        return image
    }

    private static func color(for tint: PaletteIcon.Tint) -> NSColor {
        switch tint {
        case .accent: .controlAccentColor
        case .blue: .systemBlue
        case .orange: .systemOrange
        case .green: .systemGreen
        case .purple: .systemPurple
        case .red: .systemRed
        case .secondary: .secondaryLabelColor
        }
    }
}
