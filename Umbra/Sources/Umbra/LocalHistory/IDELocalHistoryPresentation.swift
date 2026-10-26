import Foundation

/// What a revision list says about each event, and how events of one action are grouped. Pure.
enum IDELocalHistoryPresentation {
    /// Events made by one action: an agent run, one refactoring, a Save All.
    struct Group: Identifiable, Equatable {
        let id: UUID
        /// Newest first, as in the list.
        let events: [IDELocalHistoryEvent]

        var time: Date { events[0].time }
        var source: IDELocalHistorySource { events[0].source }
        var paths: [String] { events.map(\.path).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
    }

    /// Saves this close together are one Save All.
    static let saveGroupWindow: TimeInterval = 3

    static func title(for source: IDELocalHistorySource, label: String? = nil) -> String {
        if let label { return label }
        switch source {
        case .baseline: return "Opened"
        case .save: return "Saved"
        case .agent(let tab, let prompt):
            let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
            let shortened = line.count > 60 ? String(line.prefix(59)) + "…" : line
            return shortened.isEmpty ? "Agent · \(tab)" : "Agent · \(shortened)"
        case .refactor(let name): return name.isEmpty ? "Refactoring" : name
        case .revert: return "Reverted"
        case .external: return "Changed on disk"
        case .label: return "Label"
        }
    }

    static func symbol(for source: IDELocalHistorySource, label: String? = nil) -> String {
        if label != nil { return "tag.fill" }
        switch source {
        case .baseline: return "doc"
        case .save: return "square.and.arrow.down"
        case .agent: return "sparkles"
        case .refactor: return "wand.and.stars"
        case .revert: return "arrow.uturn.backward"
        case .external: return "arrow.triangle.2.circlepath"
        case .label: return "tag.fill"
        }
    }

    /// "Today", "Yesterday", else the date.
    static func dayHeading(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if now.timeIntervalSince(date) > 300 * 86_400 { return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Events (newest first) split into days, keeping their order.
    static func byDay<T>(_ items: [T], time: (T) -> Date, now: Date = Date(), calendar: Calendar = .current) -> [(heading: String, items: [T])] {
        var sections: [(heading: String, items: [T])] = []
        for item in items {
            let heading = dayHeading(for: time(item), now: now, calendar: calendar)
            if sections.last?.heading == heading { sections[sections.count - 1].items.append(item) } else { sections.append((heading, [item])) }
        }
        return sections
    }

    /// Groups newest-first events by action: neighbors with the same `group` id are one, so are saves
    /// within `saveGroupWindow` of each other; everything else stands alone.
    static func groups(_ events: [IDELocalHistoryEvent]) -> [Group] {
        var groups: [[IDELocalHistoryEvent]] = []
        for event in events {
            if let last = groups.last?.last, belongTogether(last, event) {
                groups[groups.count - 1].append(event)
            } else {
                groups.append([event])
            }
        }
        return groups.map { Group(id: $0[0].group ?? $0[0].id, events: $0) }
    }

    private static func belongTogether(_ newer: IDELocalHistoryEvent, _ older: IDELocalHistoryEvent) -> Bool {
        if let group = newer.group, group == older.group { return true }
        guard newer.group == nil, older.group == nil, newer.label == nil, older.label == nil else { return false }
        return newer.source == .save && older.source == .save && newer.time.timeIntervalSince(older.time) <= saveGroupWindow
    }

    /// "3 files", or the one path.
    static func summary(of group: Group) -> String {
        let paths = group.paths
        return paths.count == 1 ? paths[0] : "\(paths.count) files"
    }

    /// Whether to show the event when only agent changes are wanted.
    static func isAgent(_ event: IDELocalHistoryEvent) -> Bool { event.source.isAgent }

    /// "10:42", or "10:42:07" when seconds tell neighbors apart.
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }
}
