import Foundation

struct IDETabRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let isDirty: Bool
    let isSelected: Bool
    /// An SF Symbol for tabs that are not files (diagrams); files get an icon from their name.
    var symbolName: String?
}

struct IDETerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var workingDirectory: URL
    var restartRequestID: UInt64 = 0
    /// Bumped to wipe the screen and scrollback of this tab's terminal.
    var clearRequestID: UInt64 = 0
    /// Set when this tab only displays an agent command. It never starts a login shell, and it is
    /// left out of the saved session: the text lives in the view until the window closes.
    var agentCommandID: UUID?
    /// Bumped when more output is waiting for this tab's view.
    var agentFeedGeneration: UInt64 = 0

    static func defaultTitle(for directory: URL) -> String {
        let base = directory.lastPathComponent
        return base.isEmpty ? "Terminal" : base
    }

    /// A tab title short enough for the terminal strip.
    static func commandTitle(for command: String) -> String {
        let flat = command.replacing("\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 48
        guard flat.count > limit else { return flat.isEmpty ? "Command" : flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}

extension IDETerminalTab: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, workingDirectory
    }
}
