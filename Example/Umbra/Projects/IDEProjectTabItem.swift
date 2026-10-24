import SwiftUI

/// A project system's tab in the bottom panel: its glyph (a spinner while it works, red when its
/// last sync failed) and its name, drawn by the shared `IDEChromeTabItem` so it looks like every
/// other tab in the strip.
struct IDEProjectTabItem: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let isBusy: Bool
    var isFailed = false
    /// What VoiceOver hears after the name while busy: "syncing" gives "Gradle, syncing".
    var busyDescription = "running"
    var failedDescription = "failed"
    let onSelect: () -> Void

    var body: some View {
        IDEChromeTabItem(
            title: title, isSelected: isSelected, accessibilityLabel: accessibilityLabel, onSelect: onSelect,
            leading: { status }, trailing: { EmptyView() })
    }

    @ViewBuilder
    private var status: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(isFailed ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
        }
    }

    private var accessibilityLabel: String {
        if isBusy { return "\(title), \(busyDescription)" }
        return isFailed ? "\(title), \(failedDescription)" : title
    }
}
