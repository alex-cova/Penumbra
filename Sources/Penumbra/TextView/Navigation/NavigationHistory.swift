import Foundation

/// One remembered caret position for back/forward navigation (⌘[ / ⌘]).
public struct NavigationEntry: Equatable, Sendable {
    /// Identifier of the document the position belongs to, if the host tags documents
    /// (`TextView.documentIdentifier`). `nil` for a lone, untitled `TextView`.
    public var documentID: UUID?
    public var url: URL?
    public var location: TextLocation

    public init(documentID: UUID? = nil, url: URL? = nil, location: TextLocation) {
        self.documentID = documentID
        self.url = url
        self.location = location
    }

    /// Whether two entries are far enough apart to be worth a separate history stop.
    func isSignificantlyDifferent(from other: NavigationEntry, lineThreshold: Int) -> Bool {
        if documentID != other.documentID || url != other.url { return true }
        return abs(location.lineNumber - other.location.lineNumber) >= lineThreshold
    }
}

/// A bounded back/forward stack of caret positions, modelled on IntelliJ's navigation history:
/// only *significant* jumps are remembered (a big cursor move, a document switch, or an
/// explicit checkpoint before a programmatic jump), so ⌘[ steps through meaningful locations
/// rather than every keystroke.
public final class NavigationHistory {
    public private(set) var backEntries: [NavigationEntry] = []
    public private(set) var forwardEntries: [NavigationEntry] = []

    /// Maximum entries kept on either side.
    public var capacity = 64
    /// Minimum line distance for `noteCursor` to treat a move as a new stop.
    public var significantLineDelta = 10

    /// The most recent observed cursor position (not yet necessarily a history stop).
    private var lastObserved: NavigationEntry?

    public init() {}

    public var canGoBack: Bool { !backEntries.isEmpty }
    public var canGoForward: Bool { !forwardEntries.isEmpty }

    public func clear() {
        backEntries.removeAll()
        forwardEntries.removeAll()
        lastObserved = nil
    }

    /// Observes an ordinary cursor move. Pushes the *previous* position onto the back stack
    /// (and drops the forward stack) when the move is significant.
    public func noteCursor(_ entry: NavigationEntry) {
        defer { lastObserved = entry }
        guard let previous = lastObserved else { return }
        guard entry.isSignificantlyDifferent(from: previous, lineThreshold: significantLineDelta) else {
            return
        }
        pushBack(previous)
        forwardEntries.removeAll()
    }

    /// Records `entry` as a checkpoint immediately before a deliberate jump (Go to Line, Go to
    /// Definition, next search match…). Always creates a stop; clears the forward stack.
    public func recordCheckpoint(_ entry: NavigationEntry) {
        if let top = backEntries.last, !entry.isSignificantlyDifferent(from: top, lineThreshold: 1) {
            return
        }
        pushBack(entry)
        forwardEntries.removeAll()
        lastObserved = entry
    }

    /// Steps back. `current` is pushed onto the forward stack so ⌘] returns to it.
    public func goBack(from current: NavigationEntry) -> NavigationEntry? {
        guard let target = backEntries.popLast() else { return nil }
        pushForward(current)
        lastObserved = target
        return target
    }

    /// Steps forward. `current` is pushed back onto the back stack.
    public func goForward(from current: NavigationEntry) -> NavigationEntry? {
        guard let target = forwardEntries.popLast() else { return nil }
        pushBack(current)
        lastObserved = target
        return target
    }

    private func pushBack(_ entry: NavigationEntry) {
        backEntries.append(entry)
        if backEntries.count > capacity {
            backEntries.removeFirst(backEntries.count - capacity)
        }
    }

    private func pushForward(_ entry: NavigationEntry) {
        forwardEntries.append(entry)
        if forwardEntries.count > capacity {
            forwardEntries.removeFirst(forwardEntries.count - capacity)
        }
    }
}
