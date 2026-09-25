import Foundation

/// A tool-window shortcut shown in the Recent Files palette sidebar (IntelliJ-style).
public struct RecentFilesDestination: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let shortcut: String?
    public let icon: PaletteIcon?
    public let action: @MainActor @Sendable () -> Void

    public init(
        id: String,
        title: String,
        shortcut: String? = nil,
        icon: PaletteIcon? = nil,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.icon = icon
        self.action = action
    }
}
