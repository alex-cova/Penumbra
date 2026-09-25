import Foundation

/// Stages on the path from a keystroke to background intelligence.
///
/// Recording is off until a harness or the development dashboard turns ``EditorPerformanceTrace/isEnabled``
/// on. While off, ``measure`` only runs the body.
public enum EditorPerformanceStage: String, Sendable, Hashable, CaseIterable {
    case textMutation = "text_mutation"
    case caret = "caret"
    case undo = "undo"
    case incrementalParse = "incremental_parse"
    case visibleLayout = "visible_layout"
    case visibleUpdate = "visible_update"
    case completion = "completion"
    case completionPrepare = "completion_prepare"
    case diagnostics = "diagnostics"
    case indexQuery = "index_query"
    case mainThread = "main_thread"
    case frame = "frame"
    case insert = "insert"
    case delete = "delete"
    case paste = "paste"
    case multiCursor = "multi_cursor"
    case selection = "selection"
    case redo = "redo"
    case cursorMovement = "cursor_movement"
    case typingDuringBackground = "typing_during_background"
    case typingWithIntelligence = "typing_with_intelligence"
    case untilTypingObserver = "until_typing_observer"
    case syncHighlightLines = "sync_highlight_lines"
    case metalPresents = "metal_presents"
    case metalWaits = "metal_waits"
}

/// In-process stage recorder. The release harness turns it on, reads the samples, and turns it off.
public final class EditorPerformanceTrace: @unchecked Sendable {
    public static let shared = EditorPerformanceTrace()

    private let lock = NSLock()
    private var enabled = false
    private var samples: [EditorPerformanceStage: [Double]] = [:]
    private var counts: [EditorPerformanceStage: [Int]] = [:]

    public init() {}

    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    @inline(__always)
    public func measure<T>(_ stage: EditorPerformanceStage, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else {
            return try body()
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
        record(stage, seconds: seconds)
        return value
    }

    public func record(_ stage: EditorPerformanceStage, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        lock.lock()
        if enabled {
            samples[stage, default: []].append(seconds)
        }
        lock.unlock()
    }

    public func recordCount(_ stage: EditorPerformanceStage, count: Int) {
        guard count >= 0 else { return }
        lock.lock()
        if enabled {
            counts[stage, default: []].append(count)
        }
        lock.unlock()
    }

    public func counts(for stage: EditorPerformanceStage) -> [Int] {
        lock.withLock { counts[stage] ?? [] }
    }

    public func samples(for stage: EditorPerformanceStage) -> [Double] {
        lock.withLock { samples[stage] ?? [] }
    }

    public func distribution(for stage: EditorPerformanceStage) -> LatencyDistribution {
        LatencyDistributionReducer.reduce(samples(for: stage))
    }

    public func reset() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            counts.removeAll(keepingCapacity: true)
        }
    }
}
