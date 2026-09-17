import Foundation

final class TimedUndoManager: UndoManager {
    static let defaultMaxUndoGroups = 100
    static let defaultMaxUndoBytes = 64 * 1024 * 1024

    private let endGroupingInterval: TimeInterval = 1
    private var endGroupingTimer: Timer?
    private var hasOpenGroup: Bool {
        groupingLevel > 0
    }

    /// Maximum number of closed top-level undo groups. Oldest groups are discarded past this.
    var maxUndoGroups: Int = TimedUndoManager.defaultMaxUndoGroups {
        didSet {
            levelsOfUndo = max(maxUndoGroups, 1)
            trimIfNeeded()
        }
    }

    /// Approximate cap on retained undo payload (UTF-16 units × 2). Oldest groups are dropped
    /// when the running total exceeds this.
    var maxUndoBytes: Int = TimedUndoManager.defaultMaxUndoBytes {
        didSet { trimIfNeeded() }
    }

    private var groupPayloadBytes: [Int] = []
    private var currentGroupBytes = 0
    private var totalPayloadBytes = 0

    override init() {
        super.init()
        groupsByEvent = false
        levelsOfUndo = TimedUndoManager.defaultMaxUndoGroups
    }

    func notePayloadBytes(_ bytes: Int) {
        currentGroupBytes += max(0, bytes)
        trimIfNeeded()
    }

    override func removeAllActions() {
        cancelTimer()
        groupPayloadBytes.removeAll(keepingCapacity: false)
        currentGroupBytes = 0
        totalPayloadBytes = 0
        super.removeAllActions()
    }

    override func beginUndoGrouping() {
        if !hasOpenGroup {
            super.beginUndoGrouping()
            if endGroupingTimer == nil {
                scheduleTimer()
            }
        }
    }

    /// Closes a coalesced typing group if one is open, then opens a fresh group.
    /// Multi-caret and other batch edits must use this so `endUndoGrouping()` does not
    /// close the in-progress 1s typing group.
    func beginIsolatedUndoGrouping() {
        endUndoGrouping()
        beginUndoGrouping()
    }

    override func endUndoGrouping() {
        let wasOpen = hasOpenGroup
        cancelTimer()
        if hasOpenGroup {
            super.endUndoGrouping()
        }
        if wasOpen && !hasOpenGroup {
            groupPayloadBytes.append(currentGroupBytes)
            totalPayloadBytes += currentGroupBytes
            currentGroupBytes = 0
            trimIfNeeded()
        }
    }

    override func undo() {
        endUndoGrouping()
        super.undo()
    }
}

private extension TimedUndoManager {
    private func trimIfNeeded() {
        let groupCap = max(maxUndoGroups, 1)
        if levelsOfUndo != groupCap {
            levelsOfUndo = groupCap
        }
        while groupPayloadBytes.count > groupCap {
            totalPayloadBytes -= groupPayloadBytes.removeFirst()
        }
        let byteCap = max(maxUndoBytes, 0)
        while totalPayloadBytes + currentGroupBytes > byteCap && !groupPayloadBytes.isEmpty {
            let remainingGroups = groupPayloadBytes.count - 1
            levelsOfUndo = max(remainingGroups, 1)
            totalPayloadBytes -= groupPayloadBytes.removeFirst()
            levelsOfUndo = groupCap
        }
        if totalPayloadBytes < 0 {
            totalPayloadBytes = 0
        }
    }

    private func scheduleTimer() {
        let timer = Timer(timeInterval: endGroupingInterval, target: self, selector: #selector(timerDidTrigger), userInfo: nil, repeats: false)
        endGroupingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelTimer() {
        endGroupingTimer?.invalidate()
        endGroupingTimer = nil
    }

    @objc private func timerDidTrigger() {
        cancelTimer()
        endUndoGrouping()
    }
}
