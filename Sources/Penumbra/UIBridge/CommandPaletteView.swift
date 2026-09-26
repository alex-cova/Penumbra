@preconcurrency import AppKit

/// The overlay for Search Everywhere / Find Action / Recent Files / Go-to-file: an optional tab
/// strip, a query field above a grouped, keyboard-navigable results list, and a footer showing
/// the selected row's full path. Positioned and driven by `CommandPaletteController`; follows
/// the same `NSView` + baked-`CGColor` idiom as `WorkspaceSearchPanelView`.
@MainActor
public final class CommandPaletteView: NSView {
    public enum NavigationPane {
        case destinations
        case files
    }

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
    /// ←/→ between the Recent Files sidebar and file list. Returns whether it handled the key.
    public var onNavigatePane: ((Int) -> Bool)?
    /// ⌘E while Recent Files is open toggles the edited-only filter.
    public var onToggleEditedOnly: (() -> Void)?
    public var onEditedOnlyChanged: ((Bool) -> Void)?

    private enum Row {
        case header(String)
        case item(PaletteItem)
        case empty(String)
    }

    private let queryField = PaletteQueryField()
    private let searchIcon = NSImageView()
    private let searchProgress = NSProgressIndicator()
    private let hintLabel = NSTextField(labelWithString: "")
    private let materialView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let tabStack = NSStackView()
    private let tabContainer = NSView()
    private let nonProjectToggle = NSButton(checkboxWithTitle: "Include non-project items", target: nil, action: nil)
    private let navigationHeader = NSView()
    private let navigationTitle = NSTextField(labelWithString: "")
    private let editedOnlyToggle = NSButton(checkboxWithTitle: "Show edited only", target: nil, action: nil)
    private let destinationScrollView = NSScrollView()
    private let destinationTableView = NSTableView()
    private let sidebarSeparator = NSBox()
    private let footerLabel = NSTextField(labelWithString: "")
    private let splitButton = NSButton(title: "Open In Right Split", target: nil, action: nil)
    private var tabHeight: NSLayoutConstraint?
    private var sidebarWidth: NSLayoutConstraint?
    private var filesLeadingToSidebar: NSLayoutConstraint?
    private var filesLeadingToEdge: NSLayoutConstraint?
    private var queryTopToTabs: NSLayoutConstraint?
    private var queryTopToRecentHeader: NSLayoutConstraint?
    private var navigationHeaderHeight: NSLayoutConstraint?
    private var tabButtons: [(tab: PaletteTab, button: PaletteTabButton)] = []

    private var rows: [Row] = []
    /// Table row index for each item index.
    private var itemRowIndices: [Int] = []
    /// Item index for each table row (`-1` for headers).
    private var rowItemIndices: [Int] = []
    /// Table row index of the currently selected item, or `nil`.
    private var selectedTableRow: Int?
    private var selectedItemIndex = 0

    public var showsNavigationChrome = false {
        didSet { applyNavigationChrome() }
    }

    public var navigationChromeTitle = "" {
        didSet { navigationTitle.stringValue = navigationChromeTitle }
    }

    public var showsEditedOnlyInChrome = false

    public var navigationDestinations: [RecentFilesDestination] = [] {
        didSet {
            destinationTableView.reloadData()
            refreshSidebarWidth()
            refreshNavigationChrome()
        }
    }

    public var selectedDestinationIndex = 0 {
        didSet { refreshNavigationChrome() }
    }

    public var navigationPane: NavigationPane = .files {
        didSet { refreshNavigationChrome() }
    }

    public var editedOnly = false {
        didSet { editedOnlyToggle.state = editedOnly ? .on : .off }
    }

    /// Shown as a single non-selectable row when every section is empty.
    public var emptyStateMessage = "No results"

    /// Indeterminate spinner in the query row while a debounced search is in flight.
    public var isSearching = false {
        didSet { refreshSearchActivity() }
    }

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
            if !section.title.isEmpty, !showsNavigationChrome {
                newRows.append(.header(section.title))
                rowItems.append(-1)
            }
            for item in section.items {
                itemRows.append(newRows.count)
                rowItems.append(itemRows.count - 1)
                newRows.append(.item(item))
            }
        }
        if itemRows.isEmpty {
            newRows.append(.empty(emptyStateMessage))
            rowItems.append(-1)
        }
        rows = newRows
        itemRowIndices = itemRows
        rowItemIndices = rowItems
        tableView.reloadData()
        resizeTableToFitRows()
        applySelection(itemIndex: selectedItemIndex)
    }

    /// Moves the selection without rebuilding the rows — the arrow-key fast path.
    public func updateSelection(_ selectedItemIndex: Int) {
        applySelection(itemIndex: selectedItemIndex)
    }

    private func applySelection(itemIndex: Int) {
        selectedItemIndex = itemIndex
        if navigationPane == .destinations {
            tableView.deselectAll(nil)
            refreshFooter()
            return
        }
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
        destinationTableView.deselectAll(nil)
        refreshFooter()
    }

    public func refreshNavigationChrome() {
        guard showsNavigationChrome else { return }
        switch navigationPane {
        case .destinations:
            tableView.deselectAll(nil)
            guard navigationDestinations.indices.contains(selectedDestinationIndex) else {
                destinationTableView.deselectAll(nil)
                refreshFooter()
                return
            }
            destinationTableView.selectRowIndexes(
                IndexSet(integer: selectedDestinationIndex),
                byExtendingSelection: false
            )
            destinationTableView.scrollRowToVisible(selectedDestinationIndex)
            footerLabel.stringValue = navigationDestinations[selectedDestinationIndex].title
            splitButton.isHidden = true
        case .files:
            destinationTableView.deselectAll(nil)
            applySelection(itemIndex: selectedItemIndex)
        }
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

    public override func layout() {
        super.layout()
        resizeTableToFitRows()
    }

    public override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let scrollViews: [NSScrollView] = showsNavigationChrome
            ? [destinationScrollView, scrollView]
            : [scrollView]
        for scrollView in scrollViews where !scrollView.isHidden && scrollView.frame.contains(location) {
            scrollView.scrollWheel(with: event)
            return
        }
        // Query field, tabs, footer, etc. — and scroll views at their scroll limit.
    }

    /// Re-applies sidebar / query-field constraints. Call after changing tabs or chrome mode
    /// even when `showsNavigationChrome` did not change (its `didSet` would otherwise skip).
    func syncChromeLayout() {
        applyNavigationChrome()
    }

    // MARK: - Layout

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = PaletteChromeMetrics.panelCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = PaletteChromeMetrics.shadowOpacity
        layer?.shadowRadius = PaletteChromeMetrics.shadowRadius
        layer?.shadowOffset = .zero

        materialView.material = .hudWindow
        materialView.blendingMode = .withinWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = PaletteChromeMetrics.panelCornerRadius
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
        tabStack.spacing = PaletteChromeMetrics.tabStackSpacing
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.addSubview(tabStack)
        nonProjectToggle.controlSize = .small
        nonProjectToggle.font = .systemFont(ofSize: 12)
        nonProjectToggle.target = self
        nonProjectToggle.action = #selector(nonProjectToggled)
        nonProjectToggle.isHidden = true
        nonProjectToggle.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.addSubview(nonProjectToggle)

        navigationHeader.translatesAutoresizingMaskIntoConstraints = false
        navigationHeader.isHidden = true
        addSubview(navigationHeader)
        navigationTitle.font = .systemFont(
            ofSize: PaletteChromeMetrics.navigationTitleFontSize,
            weight: .semibold
        )
        navigationTitle.textColor = .labelColor
        navigationTitle.translatesAutoresizingMaskIntoConstraints = false
        navigationHeader.addSubview(navigationTitle)
        editedOnlyToggle.controlSize = .small
        editedOnlyToggle.font = .systemFont(ofSize: PaletteChromeMetrics.hintFontSize)
        editedOnlyToggle.target = self
        editedOnlyToggle.action = #selector(editedOnlyToggled)
        editedOnlyToggle.translatesAutoresizingMaskIntoConstraints = false
        navigationHeader.addSubview(editedOnlyToggle)

        // Query row.
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .tertiaryLabelColor
        searchIcon.setAccessibilityHidden(true)
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchIcon)

        searchProgress.style = .spinning
        searchProgress.controlSize = .small
        searchProgress.isIndeterminate = true
        searchProgress.isDisplayedWhenStopped = false
        searchProgress.isHidden = true
        searchProgress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchProgress)

        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.font = .systemFont(ofSize: PaletteChromeMetrics.queryFontSize, weight: .regular)
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
        queryField.onNavigatePane = { [weak self] delta in self?.onNavigatePane?(delta) ?? false }
        queryField.onToggleEditedOnly = { [weak self] in self?.onToggleEditedOnly?() }
        addSubview(queryField)

        hintLabel.font = .systemFont(ofSize: PaletteChromeMetrics.hintFontSize)
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

        destinationScrollView.translatesAutoresizingMaskIntoConstraints = false
        destinationScrollView.hasVerticalScroller = true
        destinationScrollView.borderType = .noBorder
        destinationScrollView.drawsBackground = false
        destinationScrollView.isHidden = true
        addSubview(destinationScrollView)

        sidebarSeparator.boxType = .separator
        sidebarSeparator.translatesAutoresizingMaskIntoConstraints = false
        sidebarSeparator.isHidden = true
        addSubview(sidebarSeparator)

        let destinationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("destination"))
        destinationColumn.resizingMask = .autoresizingMask
        destinationTableView.addTableColumn(destinationColumn)
        destinationTableView.headerView = nil
        destinationTableView.rowHeight = PaletteChromeMetrics.destinationRowHeight
        destinationTableView.intercellSpacing = NSSize(
            width: 0,
            height: PaletteChromeMetrics.rowIntercellSpacing
        )
        destinationTableView.delegate = self
        destinationTableView.dataSource = self
        destinationTableView.style = .plain
        destinationTableView.backgroundColor = .clear
        destinationTableView.selectionHighlightStyle = .regular
        destinationTableView.refusesFirstResponder = true
        destinationTableView.target = self
        destinationTableView.action = #selector(destinationTableClicked)
        destinationScrollView.documentView = destinationTableView

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
        tableView.rowHeight = PaletteChromeMetrics.itemRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: PaletteChromeMetrics.rowIntercellSpacing)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.floatsGroupRows = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.target = self
        tableView.action = #selector(tableViewClicked)
        tableView.refusesFirstResponder = true
        scrollView.documentView = tableView

        // Footer.
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerSeparator)

        footerLabel.font = .systemFont(ofSize: PaletteChromeMetrics.footerFontSize)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(footerLabel)

        splitButton.isBordered = false
        splitButton.font = .systemFont(ofSize: PaletteChromeMetrics.footerFontSize)
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
        let sidebarWidth = destinationScrollView.widthAnchor.constraint(equalToConstant: 0)
        self.sidebarWidth = sidebarWidth
        let filesLeadingToSidebar = scrollView.leadingAnchor.constraint(
            equalTo: sidebarSeparator.trailingAnchor,
            constant: 4
        )
        let filesLeadingToEdge = scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        self.filesLeadingToSidebar = filesLeadingToSidebar
        self.filesLeadingToEdge = filesLeadingToEdge
        filesLeadingToEdge.isActive = true

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tabContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaletteChromeMetrics.tabStripInset),
            tabContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PaletteChromeMetrics.tabStripInset),
            tabContainer.topAnchor.constraint(equalTo: topAnchor, constant: PaletteChromeMetrics.tabStripTop),
            tabHeight,
            tabStack.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            tabStack.centerYAnchor.constraint(equalTo: tabContainer.centerYAnchor),
            nonProjectToggle.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            nonProjectToggle.centerYAnchor.constraint(equalTo: tabContainer.centerYAnchor),

            navigationHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaletteChromeMetrics.horizontalInset),
            navigationHeader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PaletteChromeMetrics.horizontalInset),
            navigationHeader.topAnchor.constraint(equalTo: tabContainer.bottomAnchor, constant: 8),
            navigationTitle.leadingAnchor.constraint(equalTo: navigationHeader.leadingAnchor),
            navigationTitle.centerYAnchor.constraint(equalTo: navigationHeader.centerYAnchor),
            editedOnlyToggle.trailingAnchor.constraint(equalTo: navigationHeader.trailingAnchor),
            editedOnlyToggle.centerYAnchor.constraint(equalTo: navigationHeader.centerYAnchor),

            searchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaletteChromeMetrics.horizontalInset),
            searchIcon.centerYAnchor.constraint(equalTo: queryField.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: PaletteChromeMetrics.searchIconSize),
            searchIcon.heightAnchor.constraint(equalToConstant: PaletteChromeMetrics.searchIconSize),

            searchProgress.centerXAnchor.constraint(equalTo: searchIcon.centerXAnchor),
            searchProgress.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),

            queryField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            queryField.trailingAnchor.constraint(equalTo: hintLabel.leadingAnchor, constant: -8),
            queryField.heightAnchor.constraint(equalToConstant: PaletteChromeMetrics.queryFieldHeight),

            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PaletteChromeMetrics.horizontalInset),
            hintLabel.centerYAnchor.constraint(equalTo: queryField.centerYAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 10),

            destinationScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            sidebarWidth,
            destinationScrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            destinationScrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -4),

            sidebarSeparator.leadingAnchor.constraint(equalTo: destinationScrollView.trailingAnchor, constant: 2),
            sidebarSeparator.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            sidebarSeparator.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -4),
            sidebarSeparator.widthAnchor.constraint(equalToConstant: 1),

            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -4),

            footerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerSeparator.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -6),

            footerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaletteChromeMetrics.horizontalInset),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: splitButton.leadingAnchor, constant: -12),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            splitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PaletteChromeMetrics.horizontalInset),
            splitButton.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor)
        ])
        navigationHeaderHeight = navigationHeader.heightAnchor.constraint(equalToConstant: 0)
        navigationHeaderHeight?.isActive = true
        queryTopToTabs = queryField.topAnchor.constraint(equalTo: tabContainer.bottomAnchor, constant: 10)
        queryTopToRecentHeader = queryField.topAnchor.constraint(equalTo: navigationHeader.bottomAnchor, constant: 8)
        queryTopToTabs?.isActive = true
    }

    private func applyNavigationChrome() {
        navigationHeader.isHidden = !showsNavigationChrome
        destinationScrollView.isHidden = !showsNavigationChrome
        sidebarSeparator.isHidden = !showsNavigationChrome
        editedOnlyToggle.isHidden = !showsNavigationChrome || !showsEditedOnlyInChrome
        hintLabel.isHidden = showsNavigationChrome && showsEditedOnlyInChrome
        navigationHeaderHeight?.constant = showsNavigationChrome ? PaletteChromeMetrics.navigationHeaderHeight : 0
        refreshSidebarWidth()
        if showsNavigationChrome {
            filesLeadingToEdge?.isActive = false
            filesLeadingToSidebar?.isActive = true
            queryTopToTabs?.isActive = false
            queryTopToRecentHeader?.isActive = true
            navigationPane = .files
        } else {
            filesLeadingToSidebar?.isActive = false
            filesLeadingToEdge?.isActive = true
            queryTopToRecentHeader?.isActive = false
            queryTopToTabs?.isActive = true
        }
        destinationTableView.reloadData()
        refreshNavigationChrome()
        resizeTableToFitRows()
    }

    /// `NSTableView` is the scroll view's `documentView` and sizes itself with frames, not
    /// constraints — without this the row area can collapse to zero height after chrome changes.
    private func resizeTableToFitRows() {
        let width = scrollView.bounds.width
        guard width > 100 else { return }
        guard !rows.isEmpty else {
            if tableView.frame.size != NSSize(width: width, height: 0) {
                tableView.frame = NSRect(x: 0, y: 0, width: width, height: 0)
            }
            return
        }
        let rowStride = tableView.rowHeight + tableView.intercellSpacing.height
        let contentHeight = CGFloat(rows.count) * rowStride + 4
        let height = max(contentHeight, scrollView.bounds.height)
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        if tableView.frame != frame {
            tableView.frame = frame
        }
    }

    private func applyChromeColors() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        materialView.isHidden = reduceTransparency
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if reduceTransparency {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        if isDark {
            layer?.borderColor = NSColor.white.withAlphaComponent(PaletteChromeMetrics.darkBorderAlpha).cgColor
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func refreshSearchActivity() {
        searchIcon.isHidden = isSearching
        searchProgress.isHidden = !isSearching
        if isSearching {
            searchProgress.startAnimation(nil)
        } else {
            searchProgress.stopAnimation(nil)
        }
    }

    private func refreshSidebarWidth() {
        guard showsNavigationChrome else {
            sidebarWidth?.constant = 0
            return
        }
        let titleFont = NSFont.systemFont(ofSize: PaletteChromeMetrics.destinationFontSize)
        let shortcutFont = NSFont.monospacedSystemFont(
            ofSize: PaletteChromeMetrics.shortcutFontSize,
            weight: .regular
        )
        var width = PaletteChromeMetrics.sidebarMinWidth
        for destination in navigationDestinations {
            let titleWidth = (destination.title as NSString).size(withAttributes: [.font: titleFont]).width
            let shortcutWidth: CGFloat
            if let shortcut = destination.shortcut {
                shortcutWidth = (shortcut as NSString).size(withAttributes: [.font: shortcutFont]).width
            } else {
                shortcutWidth = 0
            }
            let rowWidth = PaletteChromeMetrics.sidebarLeadingPadding
                + PaletteChromeMetrics.destinationIconSize
                + 8
                + titleWidth
                + 8
                + shortcutWidth
                + PaletteChromeMetrics.sidebarTrailingPadding
            width = max(width, rowWidth)
        }
        sidebarWidth?.constant = min(
            max(width, PaletteChromeMetrics.sidebarMinWidth),
            PaletteChromeMetrics.sidebarMaxWidth
        )
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
        tabHeight?.constant = tabs.isEmpty ? 0 : PaletteChromeMetrics.tabHeight
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

    @objc private func editedOnlyToggled() {
        onEditedOnlyChanged?(editedOnlyToggle.state == .on)
        focusQueryField()
    }

    @objc private func destinationTableClicked() {
        let row = destinationTableView.clickedRow
        guard navigationDestinations.indices.contains(row) else { return }
        selectedDestinationIndex = row
        navigationPane = .destinations
        onConfirm?()
    }

    @objc private func splitButtonClicked() {
        onConfirmAlternate?()
    }

    @objc private func tableViewClicked() {
        let clickedRow = tableView.clickedRow
        guard rowItemIndices.indices.contains(clickedRow), rowItemIndices[clickedRow] >= 0 else { return }
        navigationPane = .files
        onActivateItemAtIndex?(rowItemIndices[clickedRow])
    }

    // MARK: - Row content

    private static let titleFont = NSFont.systemFont(ofSize: PaletteChromeMetrics.titleFontSize)
    private static let boldTitleFont = NSFont.boldSystemFont(ofSize: PaletteChromeMetrics.titleFontSize)

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
        if tableView === destinationTableView { return navigationDestinations.count }
        return rows.count
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if tableView === destinationTableView { return false }
        if case .header = rows[row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === destinationTableView { return true }
        if case .item = rows[row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, selectionHighlightStyleForRow row: Int) -> NSTableView.SelectionHighlightStyle {
        if tableView === destinationTableView { return .regular }
        if case .empty = rows[row] { return .none }
        return .regular
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if tableView === destinationTableView {
            let id = NSUserInterfaceItemIdentifier("destinationRow")
            return tableView.makeView(withIdentifier: id, owner: self) as? NSTableRowView ?? {
                let created = PaletteRowView()
                created.identifier = id
                return created
            }()
        }
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
        if tableView === destinationTableView {
            let destination = navigationDestinations[row]
            let id = NSUserInterfaceItemIdentifier("destinationCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? PaletteDestinationCell
                ?? PaletteDestinationCell(id: id)
            cell.apply(destination: destination)
            return cell
        }
        switch rows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("headerCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? Self.makeLabelCell(id: id)
            cell.textField?.stringValue = title
            cell.textField?.textColor = .tertiaryLabelColor
            cell.textField?.font = .systemFont(ofSize: PaletteChromeMetrics.headerFontSize, weight: .semibold)
            return cell
        case .empty(let message):
            let id = NSUserInterfaceItemIdentifier("emptyCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? Self.makeLabelCell(id: id)
            cell.textField?.stringValue = message
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: PaletteChromeMetrics.locationFontSize)
            cell.setAccessibilityElement(true)
            cell.setAccessibilityLabel(message)
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
    var onNavigatePane: ((Int) -> Bool)?
    var onToggleEditedOnly: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "e",
           onToggleEditedOnly != nil {
            onToggleEditedOnly?()
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)):
            if onNavigatePane?(-1) != true { super.doCommand(by: selector) }
        case #selector(NSResponder.moveRight(_:)):
            if onNavigatePane?(1) != true { super.doCommand(by: selector) }
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
        let insetX = PaletteChromeMetrics.selectionInsetX
        let verticalInset = PaletteChromeMetrics.selectionVerticalInset
        let barRect = NSRect(
            x: bounds.minX + insetX,
            y: bounds.minY + verticalInset,
            width: PaletteChromeMetrics.selectionAccentBarWidth,
            height: bounds.height - (verticalInset * 2)
        )
        NSColor.controlAccentColor.setFill()
        barRect.fill()

        let rect = bounds.insetBy(dx: insetX, dy: 0)
        NSColor.controlAccentColor.withAlphaComponent(PaletteChromeMetrics.selectionFillAlpha).setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: PaletteChromeMetrics.innerCornerRadius,
            yRadius: PaletteChromeMetrics.innerCornerRadius
        ).fill()
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
        font = .systemFont(ofSize: PaletteChromeMetrics.tabFontSize, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = PaletteChromeMetrics.innerCornerRadius
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
        size.height = PaletteChromeMetrics.tabButtonHeight
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
            attributes: [
                .foregroundColor: color,
                .font: font ?? NSFont.systemFont(ofSize: PaletteChromeMetrics.tabFontSize)
            ]
        )
        layer?.backgroundColor = isSelectedTab
            ? NSColor.controlAccentColor.withAlphaComponent(PaletteChromeMetrics.tabFillAlpha).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = isSelectedTab ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(PaletteChromeMetrics.tabBorderAlpha).cgColor
        setAccessibilityLabel(title)
        setAccessibilitySelected(isSelectedTab)
    }
}

private final class PaletteDestinationCell: NSTableCellView {
    private let iconView = NSImageView()
    private let shortcutField = NSTextField(labelWithString: "")

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        addSubview(textField)
        self.textField = textField

        shortcutField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.font = .monospacedSystemFont(ofSize: PaletteChromeMetrics.shortcutFontSize, weight: .regular)
        shortcutField.textColor = .tertiaryLabelColor
        shortcutField.alignment = .right
        shortcutField.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(shortcutField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaletteChromeMetrics.sidebarLeadingPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PaletteChromeMetrics.destinationIconSize),
            iconView.heightAnchor.constraint(equalToConstant: PaletteChromeMetrics.destinationIconSize),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: shortcutField.leadingAnchor, constant: -8),

            shortcutField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PaletteChromeMetrics.sidebarTrailingPadding),
            shortcutField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(destination: RecentFilesDestination) {
        textField?.stringValue = destination.title
        textField?.font = .systemFont(ofSize: PaletteChromeMetrics.destinationFontSize)
        textField?.textColor = .labelColor
        if let icon = destination.icon,
           let image = NSImage(systemSymbolName: icon.systemName, accessibilityDescription: nil) {
            iconView.image = image
            iconView.contentTintColor = paletteIconColor(for: icon.tint)
            iconView.isHidden = false
            iconView.setAccessibilityHidden(true)
        } else {
            iconView.isHidden = true
        }
        shortcutField.stringValue = destination.shortcut ?? ""
        shortcutField.isHidden = destination.shortcut == nil
        shortcutField.setAccessibilityHidden(true)
        textField?.setAccessibilityHidden(true)

        var label = destination.title
        if let shortcut = destination.shortcut, !shortcut.isEmpty {
            label += ", \(shortcut)"
        }
        setAccessibilityElement(true)
        setAccessibilityLabel(label)
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
        locationField.font = .systemFont(ofSize: PaletteChromeMetrics.locationFontSize)
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
            iconView.widthAnchor.constraint(equalToConstant: PaletteChromeMetrics.itemIconSize),
            iconView.heightAnchor.constraint(equalToConstant: PaletteChromeMetrics.itemIconSize),

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
                ? .monospacedSystemFont(ofSize: PaletteChromeMetrics.shortcutFontSize, weight: .regular)
                : .systemFont(ofSize: PaletteChromeMetrics.locationFontSize)
            trailingField.textColor = trailingIsShortcut ? .tertiaryLabelColor : .secondaryLabelColor
            trailingField.isHidden = false
        } else {
            trailingField.stringValue = ""
            trailingField.isHidden = true
        }

        iconView.setAccessibilityHidden(true)
        textField?.setAccessibilityHidden(true)
        locationField.setAccessibilityHidden(true)
        trailingField.setAccessibilityHidden(true)

        var label = title.string
        if let location, !location.isEmpty {
            label += ", \(location)"
        }
        if let trailing, !trailing.isEmpty {
            label += ", \(trailing)"
        }
        setAccessibilityElement(true)
        setAccessibilityLabel(label)
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
        paletteIconColor(for: tint)
    }
}

private func paletteIconColor(for tint: PaletteIcon.Tint) -> NSColor {
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
