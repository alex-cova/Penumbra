@preconcurrency import AppKit

/// Detects a "double tap" of a bare modifier key — two press-and-release cycles of the same
/// modifier, with nothing else pressed in between, inside a short window. IntelliJ's Search
/// Everywhere (double ⇧) is the motivating case.
///
/// Fed from `flagsChanged(with:)` for the modifier transitions and from `keyDown`/`mouseDown`
/// (via ``noteOtherInput()``) so an intervening key press cancels a pending double tap.
struct DoubleModifierDetector {
    /// Maximum gap between the first release and the second press.
    var window: TimeInterval = 0.3

    /// The modifier being watched. Defaults to Shift.
    var trackedFlag: NSEvent.ModifierFlags = .shift

    private enum Phase {
        case idle
        /// The tracked modifier went down once and came back up at `releasedAt`.
        case armed(releasedAt: TimeInterval)
    }

    private var phase: Phase = .idle
    private var isTrackedDown = false

    /// Call from `flagsChanged(with:)`. Returns `true` when this transition completes a
    /// double tap.
    mutating func handleFlagsChanged(_ event: NSEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let masked = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let onlyTracked = masked == trackedFlag
        let noneDown = masked.isEmpty
        let trackedNowDown = masked.contains(trackedFlag)

        // Any other modifier held alongside (or instead of) the tracked one cancels.
        if !masked.isEmpty && !onlyTracked {
            phase = .idle
            isTrackedDown = trackedNowDown
            return false
        }

        let wasDown = isTrackedDown
        isTrackedDown = trackedNowDown

        if !wasDown && trackedNowDown {
            // Press.
            if case .armed(let releasedAt) = phase, now - releasedAt <= window {
                phase = .idle
                return true
            }
            phase = .idle
        } else if wasDown && noneDown {
            // Release.
            phase = .armed(releasedAt: now)
        }
        return false
    }

    /// Call when any non-modifier input occurs, so it cancels a half-formed double tap.
    mutating func noteOtherInput() {
        phase = .idle
    }
}
