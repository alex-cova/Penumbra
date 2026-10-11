import Foundation

/// Undo steps for a hex document.
///
/// Consecutive coalescable edits within 500 ms at adjacent offsets become one step.
/// The stack keeps at most 1,000 steps. Dropping the oldest does not clear the dirty
/// counter or the changed-byte total: those bytes are still unsaved.
public struct HexUndoStack: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var location: Int64
        public var removed: [UInt8]
        public var inserted: [UInt8]
        public var coalescable: Bool
        public var time: ContinuousClock.Instant
        public var contribution: Int64

        public init(
            location: Int64,
            removed: [UInt8],
            inserted: [UInt8],
            coalescable: Bool,
            time: ContinuousClock.Instant,
            contribution: Int64
        ) {
            self.location = location
            self.removed = removed
            self.inserted = inserted
            self.coalescable = coalescable
            self.time = time
            self.contribution = contribution
        }
    }

    public static let limit = 1_000
    public static let coalesceWindow: Duration = .milliseconds(500)

    public private(set) var undo: [Entry] = []
    public private(set) var redo: [Entry] = []
    /// Distance from the clean state. Zero is clean. A document loaded already dirty starts at 1.
    public private(set) var unsavedEdits: Int = 0
    public private(set) var changedByteCount: Int64 = 0

    public init() {}

    public var canUndo: Bool { !undo.isEmpty }
    public var canRedo: Bool { !redo.isEmpty }
    public var isDirty: Bool { unsavedEdits != 0 }

    public mutating func clear() {
        undo.removeAll()
        redo.removeAll()
        unsavedEdits = 0
        changedByteCount = 0
    }

    /// Marks a document dirty before any undoable step exists (a text buffer reopened as hex).
    public mutating func markAlreadyDirty(changedBytes: Int64) {
        unsavedEdits = max(unsavedEdits, 1)
        changedByteCount = max(changedByteCount, changedBytes)
    }

    public mutating func record(
        location: Int64,
        removed: [UInt8],
        inserted: [UInt8],
        coalescable: Bool,
        now: ContinuousClock.Instant
    ) {
        redo.removeAll()
        if coalescable, var last = undo.last, last.coalescable,
           now >= last.time, now - last.time <= Self.coalesceWindow {
            // The second nibble rewrites the byte the first nibble just wrote. Keep the original
            // removed bytes so one undo restores the byte from before the keystroke.
            if removed.count == 1, inserted.count == 1, let previous = last.inserted.last,
               previous == removed[0],
               location == last.location + Int64(last.inserted.count) - 1 {
                last.inserted[last.inserted.count - 1] = inserted[0]
                last.time = now
                undo[undo.count - 1] = last
                return
            }
            if canExtend(last, location: location, removed: removed, inserted: inserted) {
                let previous = last.contribution
                last.removed.append(contentsOf: removed)
                last.inserted.append(contentsOf: inserted)
                last.time = now
                last.contribution = Self.contribution(removed: last.removed, inserted: last.inserted)
                undo[undo.count - 1] = last
                changedByteCount += last.contribution - previous
                return
            }
        }
        if undo.count >= Self.limit {
            undo.removeFirst()
        }
        let entry = Entry(
            location: location,
            removed: removed,
            inserted: inserted,
            coalescable: coalescable,
            time: now,
            contribution: Self.contribution(removed: removed, inserted: inserted)
        )
        undo.append(entry)
        unsavedEdits += 1
        changedByteCount += entry.contribution
    }

    public mutating func popUndo() -> Entry? {
        guard let entry = undo.popLast() else { return nil }
        redo.append(entry)
        unsavedEdits -= 1
        changedByteCount -= entry.contribution
        return entry
    }

    public mutating func popRedo() -> Entry? {
        guard let entry = redo.popLast() else { return nil }
        undo.append(entry)
        unsavedEdits += 1
        changedByteCount += entry.contribution
        return entry
    }

    public static func contribution(removed: [UInt8], inserted: [UInt8]) -> Int64 {
        Int64(max(removed.count, inserted.count))
    }

    private func canExtend(_ last: Entry, location: Int64, removed: [UInt8], inserted: [UInt8]) -> Bool {
        let lastEnd = last.location + Int64(last.inserted.count)
        guard location == lastEnd else { return false }
        if removed.isEmpty && last.removed.isEmpty && inserted.count == 1 {
            return true
        }
        return removed.count == 1 && inserted.count == 1 && last.removed.count == last.inserted.count
    }
}
