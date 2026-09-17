import Foundation

/// Back/forward stack of selected document IDs (most recent at index 0).
public final class EditorTabHistory: @unchecked Sendable {
    private var entries: [UUID] = []
    private var offset = 0
    private var suppressRecording = false

    public var canGoBack: Bool {
        !entries.isEmpty && offset < entries.count - 1
    }

    public var canGoForward: Bool {
        offset > 0
    }

    public func recordSelection(_ documentID: UUID) {
        guard !suppressRecording else { return }
        if entries.first == documentID { return }
        clearFuture()
        entries.insert(documentID, at: 0)
    }

    public func clearFuture() {
        guard offset > 0 else { return }
        entries.removeFirst(offset)
        offset = 0
    }

    public func goBack() -> UUID? {
        guard canGoBack else { return nil }
        offset += 1
        return entries[offset]
    }

    public func goForward() -> UUID? {
        guard canGoForward else { return nil }
        offset -= 1
        return entries[offset]
    }

    public func remove(documentID: UUID) {
        entries.removeAll { $0 == documentID }
        if entries.isEmpty {
            offset = 0
        } else {
            offset = min(offset, entries.count - 1)
        }
    }

    public func navigate(to documentID: UUID) {
        suppressRecording = true
        defer { suppressRecording = false }
        if let index = entries.firstIndex(of: documentID) {
            offset = index
        }
    }

    public func snapshotEntries() -> [UUID] {
        entries
    }

    public func snapshotOffset() -> Int {
        offset
    }

    public func restore(entries: [UUID], offset: Int) {
        self.entries = entries
        self.offset = entries.isEmpty ? 0 : min(max(0, offset), entries.count - 1)
        suppressRecording = false
    }
}
