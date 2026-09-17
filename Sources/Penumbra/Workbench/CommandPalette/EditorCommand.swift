import Foundation

/// A single command palette entry.
public struct EditorCommand: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let group: String
    /// A pre-formatted label to display alongside the command, e.g. `"⌘K"`. Plain text rather
    /// than a structured shortcut: organizing/filtering commands is this type's job, not owning
    /// keyboard-shortcut dispatch — wire that through `TextView.keyDownHandler` or your own event
    /// loop instead.
    public let shortcutDisplay: String?
    public let action: @MainActor @Sendable () -> Void

    public init(id: String, title: String, group: String, shortcutDisplay: String? = nil, action: @escaping @MainActor @Sendable () -> Void) {
        self.id = id
        self.title = title
        self.group = group
        self.shortcutDisplay = shortcutDisplay
        self.action = action
    }
}

/// Commands sharing a `group`, in the order groups were first registered.
public struct CommandGroup: Identifiable {
    public var id: String { name }
    public let name: String
    public let commands: [EditorCommand]
}

/// Registry of ``EditorCommand``s, with fuzzy filtering for a command-palette UI backed by
/// ``FuzzyMatcher``.
@MainActor
public final class CommandRegistry {
    public private(set) var commands: [EditorCommand] = []

    public init() {}

    /// Registers `command`, replacing any existing command with the same `id` (last writer wins);
    /// otherwise appended, so registration order determines fuzzy-match tie-breaking and
    /// ``commandGroups`` ordering.
    public func register(_ command: EditorCommand) {
        commands.removeAll { $0.id == command.id }
        commands.append(command)
    }

    public func register(_ commands: [EditorCommand]) {
        for command in commands {
            register(command)
        }
    }

    public func command(id: String) -> EditorCommand? {
        commands.first { $0.id == id }
    }

    /// Commands matching `query`, ranked by ``FuzzyMatcher``. An empty query returns the first 40
    /// registered commands, unranked.
    public func filtered(query: String) -> [EditorCommand] {
        FuzzyMatcher.ranked(query: query, items: commands, key: \.title, limit: 40)
    }

    /// Like ``filtered(query:)`` but also returns each command's ``FuzzyMatcher/Match`` so a
    /// palette can highlight the matched characters.
    public func filteredWithMatches(query: String, limit: Int = 40) -> [(command: EditorCommand, match: FuzzyMatcher.Match)] {
        FuzzyMatcher.rankedWithMatches(query: query, items: commands, key: \.title, limit: limit)
            .map { ($0.item, $0.match) }
    }

    /// Commands grouped by `group`, preserving the order each group was first seen in
    /// `commands` — not alphabetical, and not affected by re-registering an existing command.
    public var commandGroups: [CommandGroup] {
        var order: [String] = []
        var grouped: [String: [EditorCommand]] = [:]
        for command in commands {
            if !order.contains(command.group) {
                order.append(command.group)
            }
            grouped[command.group, default: []].append(command)
        }
        return order.compactMap { name in
            guard let commands = grouped[name], !commands.isEmpty else { return nil }
            return CommandGroup(name: name, commands: commands)
        }
    }
}
