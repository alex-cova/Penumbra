import AppKit

/// Shared layout tokens for ``CommandPaletteView`` chrome (panel, rows, sidebar, selection).
enum PaletteChromeMetrics {
    static let panelCornerRadius: CGFloat = 12
    static let innerCornerRadius: CGFloat = 6
    static let selectionInsetX: CGFloat = 6

    static let horizontalInset: CGFloat = 16
    static let tabStripInset: CGFloat = 12
    static let tabStripTop: CGFloat = 10
    static let tabHeight: CGFloat = 28
    static let tabButtonHeight: CGFloat = 24
    static let tabStackSpacing: CGFloat = 4

    static let navigationHeaderHeight: CGFloat = 24
    static let queryFieldHeight: CGFloat = 28
    static let queryBoxVerticalPadding: CGFloat = 5
    static let queryBoxBorderWidth: CGFloat = 1.5
    static let queryBoxFocusedBorderWidth: CGFloat = 2
    static let queryBoxFillAlpha: CGFloat = 0.25
    static let queryBoxUnfocusedBorderAlpha: CGFloat = 0.55
    static let emptyStateRowHeight: CGFloat = 44
    static let emptyStateIconSize: CGFloat = 20
    static let queryFontSize: CGFloat = 17
    static let navigationTitleFontSize: CGFloat = 15

    static let itemRowHeight: CGFloat = 24
    static let destinationRowHeight: CGFloat = 26
    /// Zero so test-row tints read as one continuous band.
    static let rowIntercellSpacing: CGFloat = 0

    static let titleFontSize: CGFloat = 13
    static let locationFontSize: CGFloat = 12
    static let footerFontSize: CGFloat = 12
    static let footerShortcutSpacing: CGFloat = 12
    static let footerShortcutKeyFontSize: CGFloat = 11
    static let footerShortcutTitleFontSize: CGFloat = 11
    static let footerShortcutKeyPaddingX: CGFloat = 5
    static let footerShortcutKeyPaddingY: CGFloat = 2
    static let footerShortcutKeyCornerRadius: CGFloat = 4
    static let footerShortcutKeyFillAlpha: CGFloat = 0.12
    static let hintFontSize: CGFloat = 12
    static let tabFontSize: CGFloat = 12
    static let headerFontSize: CGFloat = 11
    static let headerTracking: CGFloat = 0.6
    static let shortcutFontSize: CGFloat = 11
    static let destinationFontSize: CGFloat = 13

    static let sidebarMinWidth: CGFloat = 168
    static let sidebarMaxWidth: CGFloat = 200
    static let sidebarLeadingPadding: CGFloat = 10
    static let sidebarTrailingPadding: CGFloat = 10
    static let destinationIconSize: CGFloat = 14
    static let itemIconSize: CGFloat = 16
    static let searchIconSize: CGFloat = 16

    static let shadowOpacityLight: Float = 0.45
    static let shadowOpacityDark: Float = 0.65
    static let shadowRadius: CGFloat = 24
    static let selectionFillAlpha: CGFloat = 0.32
    static let testRowTintAlpha: CGFloat = 0.07
    /// Widest the right-aligned module column may grow, as a fraction of the row.
    static let trailingColumnMaxFraction: CGFloat = 0.3
    static let tabFillAlpha: CGFloat = 0.25
    static let tabBorderAlpha: CGFloat = 0.7
    static let darkBorderAlpha: CGFloat = 0.08

    /// Show the query-row spinner only when a search is debounced long enough to feel latent.
    static let searchingIndicatorMinimumDebounce: UInt64 = 50
}
