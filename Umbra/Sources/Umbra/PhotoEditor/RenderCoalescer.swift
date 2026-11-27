import Foundation

/// Preview render fidelity. `interactive` frames are rendered from a small proxy while a slider is
/// moving; `final` is the crisp frame produced when the drag ends (and the only tier that also
/// refreshes the histogram).
nonisolated enum RenderQuality: Sendable, Equatable {
    case interactive
    case final

    /// `final` always wins, so a queued high-quality frame is never downgraded by a later
    /// interactive tick that arrived before the render loop drained.
    static func higher(_ lhs: RenderQuality, _ rhs: RenderQuality) -> RenderQuality {
        (lhs == .final || rhs == .final) ? .final : .interactive
    }
}

/// One unit of work for the render loop.
nonisolated struct RenderRequest: Sendable, Equatable {
    var adjustments: EditAdjustment
    var quality: RenderQuality
    /// The RAW source must be re-decoded before this render because `adjustments.raw` changed.
    var rawNeedsDecode: Bool

    init(adjustments: EditAdjustment, quality: RenderQuality, rawNeedsDecode: Bool = false) {
        self.adjustments = adjustments
        self.quality = quality
        self.rawNeedsDecode = rawNeedsDecode
    }
}

/// Single-slot render queue: at most one request waits at a time, and it always carries the newest
/// recipe. Merging keeps the stronger `quality` and a sticky `rawNeedsDecode` until the request is
/// taken. Pure value type so the coalescing rule is unit-tested independently of the session.
nonisolated struct RenderCoalescer: Sendable {
    private var pending: RenderRequest?

    var hasPending: Bool { pending != nil }

    mutating func enqueue(_ request: RenderRequest) {
        guard var current = pending else {
            pending = request
            return
        }
        current.adjustments = request.adjustments
        current.quality = RenderQuality.higher(current.quality, request.quality)
        current.rawNeedsDecode = current.rawNeedsDecode || request.rawNeedsDecode
        pending = current
    }

    mutating func takeNext() -> RenderRequest? {
        defer { pending = nil }
        return pending
    }
}
