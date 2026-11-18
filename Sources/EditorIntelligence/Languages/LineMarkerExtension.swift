import Foundation

/// How a gutter marker defined by a language or framework layer looks and is identified. A descriptor is a value the
/// service declares once (``LanguageService/lineMarkerDescriptors``); a marker only points at it, so a host can list
/// every kind in preferences, toggle it, draw it and speak it without knowing the layer that made it.
public struct LineMarkerDescriptor: Hashable, Sendable, Identifiable {
    /// A namespaced identifier (`spring.bean`). Saved in preferences, so it must not change once shipped.
    public struct ID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, Comparable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public static func < (lhs: ID, rhs: ID) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A meaning, never a colour: the host maps it to its theme in light and dark appearance.
    public enum Tint: String, Sendable, CaseIterable {
        case neutral, accent, interface, override, success, warning, danger
    }

    public let id: ID
    /// The name in Settings (`Spring beans`).
    public let title: String
    /// The section in Settings the toggle sits under (`Spring`).
    public let group: String
    /// An SF Symbol name.
    public let symbolName: String
    public let tint: Tint
    /// Which marker takes the visible slot when several share a line; higher wins. Built-in kinds use ``LineMarkerKind/stackPriority``.
    public let priority: Int
    /// What VoiceOver says for the marker (`Spring bean`).
    public let accessibilityLabel: String

    public init(id: ID, title: String, group: String, symbolName: String, tint: Tint = .neutral, priority: Int = 40, accessibilityLabel: String? = nil) {
        self.id = id
        self.title = title
        self.group = group
        self.symbolName = symbolName
        self.tint = tint
        self.priority = priority
        self.accessibilityLabel = accessibilityLabel ?? title
    }
}

/// What choosing a marker action does. Every case is something the host already knows how to do.
public enum LineMarkerAction: Sendable {
    /// Navigate from the marker's own position (Go to Implementation, Find Usages…), through the language's providers.
    case navigate(NavigationKind)
    /// Open these places, or ask which when there are several.
    case open([Location])
    /// A command the host registered (`id` and its arguments); a host that does not know the id does nothing.
    case command(CodeActionCommand)
}

public struct LineMarkerMenuItem: Sendable {
    public let title: String
    /// An SF Symbol name for the menu row.
    public let symbolName: String?
    public let action: LineMarkerAction

    public init(title: String, symbolName: String? = nil, action: LineMarkerAction) {
        self.title = title
        self.symbolName = symbolName
        self.action = action
    }
}

public extension LineMarkerKind {
    /// Where a built-in kind ranks against extension markers when they share a line.
    var stackPriority: Int {
        switch self {
        case .implementing, .overriding: return 60
        case .implemented, .overridden: return 60
        case .siblingInherited: return 55
        case .recursiveCall: return 10
        case .extended: return 0
        }
    }
}

public extension LineMarker {
    var stackPriority: Int { descriptor?.priority ?? kind.stackPriority }
}

/// The markers that share one gutter line, in the order the host presents them.
public struct LineMarkerStack: Sendable {
    public let line: Int
    /// Highest priority first; ties by identity, so the order never depends on which provider answered first.
    public let markers: [LineMarker]
    /// The marker drawn in the gutter slot.
    public var visible: LineMarker { markers[0] }
    /// More than one marker: the host draws a count and opens a menu listing all of them instead of picking one.
    public var isStacked: Bool { markers.count > 1 }
}

public enum LineMarkerPresentation {
    /// Groups `markers` by line, drops exact repeats (same descriptor or kind, line and anchor), and orders each line's
    /// markers by priority. Nothing is discarded except a repeat: a lower-priority marker stays in the stack.
    public static func stacks(from markers: [LineMarker]) -> [LineMarkerStack] {
        var seen = Set<String>()
        var byLine: [Int: [LineMarker]] = [:]
        for marker in markers where seen.insert(marker.identity).inserted { byLine[marker.line, default: []].append(marker) }
        return byLine.keys.sorted().map { line in
            let ordered = byLine[line]!.sorted {
                $0.stackPriority != $1.stackPriority ? $0.stackPriority > $1.stackPriority : $0.identity < $1.identity
            }
            return LineMarkerStack(line: line, markers: ordered)
        }
    }
}
