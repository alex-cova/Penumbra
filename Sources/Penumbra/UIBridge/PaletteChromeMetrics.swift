import AppKit

/// Shared layout tokens for ``CommandPaletteView`` chrome (panel, rows, sidebar, selection).
enum PaletteChromeMetrics {
    static let panelCornerRadius: CGFloat = 12
    static let innerCornerRadius: CGFloat = 6
    static let selectionInsetX: CGFloat = 6
    static let selectionAccentBarWidth: CGFloat = 2
    static let selectionVerticalInset: CGFloat = 2

    static let horizontalInset: CGFloat = 16
    static let tabStripInset: CGFloat = 12
    static let tabStripTop: CGFloat = 10
    static let tabHeight: CGFloat = 28
    static let tabButtonHeight: CGFloat = 24
    static let tabStackSpacing: CGFloat = 4

    static let navigationHeaderHeight: CGFloat = 24
    static let queryFieldHeight: CGFloat = 28
    static let queryFontSize: CGFloat = 17
    static let navigationTitleFontSize: CGFloat = 15

    static let itemRowHeight: CGFloat = 24
    static let destinationRowHeight: CGFloat = 26
    static let rowIntercellSpacing: CGFloat = 1

    static let titleFontSize: CGFloat = 13
    static let locationFontSize: CGFloat = 12
    static let footerFontSize: CGFloat = 12
    static let hintFontSize: CGFloat = 12
    static let tabFontSize: CGFloat = 12
    static let headerFontSize: CGFloat = 11
    static let shortcutFontSize: CGFloat = 11
    static let destinationFontSize: CGFloat = 13

    static let sidebarMinWidth: CGFloat = 168
    static let sidebarMaxWidth: CGFloat = 200
    static let sidebarLeadingPadding: CGFloat = 10
    static let sidebarTrailingPadding: CGFloat = 10
    static let destinationIconSize: CGFloat = 14
    static let itemIconSize: CGFloat = 16
    static let searchIconSize: CGFloat = 16

    static let shadowOpacity: Float = 0.45
    static let shadowRadius: CGFloat = 24
    static let selectionFillAlpha: CGFloat = 0.22
    static let tabFillAlpha: CGFloat = 0.25
    static let tabBorderAlpha: CGFloat = 0.7
    static let darkBorderAlpha: CGFloat = 0.08

    /// Show the query-row spinner only when a search is debounced long enough to feel latent.
    static let searchingIndicatorMinimumDebounce: UInt64 = 50
}
