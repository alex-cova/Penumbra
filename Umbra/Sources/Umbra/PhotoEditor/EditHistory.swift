import Foundation

/// Undo/redo stack over `EditAdjustment` snapshots (not rendered bitmaps).
nonisolated struct EditHistory: Sendable {
    private(set) var present: EditAdjustment
    private var past: [EditAdjustment] = []
    private var future: [EditAdjustment] = []
    private let depthCap = 100

    init(_ initial: EditAdjustment) {
        present = initial
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    mutating func commit(_ next: EditAdjustment) {
        guard next != present else { return }
        past.append(present)
        if past.count > depthCap {
            past.removeFirst(past.count - depthCap)
        }
        present = next
        future.removeAll()
    }

    mutating func undo() {
        guard let previous = past.popLast() else { return }
        future.append(present)
        present = previous
    }

    mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(present)
        present = next
    }
}
