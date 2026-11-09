import Foundation
import os

/// An opt-in timeline of completion requests, from the keystroke the controller observed to the
/// popup's first draw, correlated across the main actor, the engine's task and the providers' tasks
/// by a request id (``CompletionContext/traceID``, the controller's generation counter).
///
/// Off by default: with tracing off every call is one boolean read. Turn it on with the
/// `UMBRA_COMPLETION_TRACE=1` environment variable (one summary line per request on standard error)
/// or ``setEnabled(_:)`` (tests and the release harness read ``events(for:)`` themselves).
///
/// All times come from one monotonic clock (`DispatchTime.now().uptimeNanoseconds`). `NSEvent.timestamp`
/// is a different unit (seconds of system uptime) and is not read, so the time between the key being
/// pressed and the controller seeing the typed character is not part of the timeline. The boundaries it
/// can see, in order:
///
/// | event | where | meaning |
/// |---|---|---|
/// | `typed` | controller | the typing observer ran: the buffer already holds the character |
/// | `requestBegin` | controller | `requestCompletion` started (backdated; the live document is built after it) |
/// | `scheduled` | controller | the request is built: document, context, prefix |
/// | `taskStart` | controller | the async task that calls the engine began running |
/// | `engineQueued` | engine | `completeUpdates` was called |
/// | `engineStart` | engine | the debounce is over and the providers are launched |
/// | `provider:<name>` | engine | that provider's update reached the engine |
/// | `snapshot` | engine | a merged, ranked snapshot was published to the controller |
/// | `ingest` | controller | the snapshot reached the main actor, with what the controller did with it |
/// | `holdRelease` | controller | the 300 ms hold expired and presented the parked update |
/// | `presented` | controller | the popup's state and view were updated and it is visible |
/// | `panelDraw` | panel view | the first `draw(_:)` of the panel after that: the closest boundary to pixels |
/// | `superseded` | controller | a newer request replaced this one before it was presented |
///
/// `panelDraw` is the last point the app can observe. Whether the window server has put the frame on
/// screen after it is not measured.
public enum CompletionLatencyTrace {
    public struct Event: Sendable {
        public let request: Int
        public let name: String
        public let detail: String
        public let nanoseconds: UInt64
    }

    private struct State {
        var events: [Event] = []
        var drawPending: Int?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    // Flipped by tests and the harness before a run; a stale read costs one missed or extra event.
    nonisolated(unsafe) private static var enabled = ProcessInfo.processInfo.environment["UMBRA_COMPLETION_TRACE"] == "1"
    nonisolated(unsafe) private static var printsSummaries = ProcessInfo.processInfo.environment["UMBRA_COMPLETION_TRACE"] == "1"
    /// Past this many events nothing more is kept, so a session left tracing cannot grow without bound.
    private static let capacity = 50_000

    public static var isEnabled: Bool { enabled }

    public static func setEnabled(_ on: Bool, printingSummaries: Bool = false) {
        enabled = on
        printsSummaries = on && printingSummaries
    }

    public static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Records `name` for `request`. `time` backdates the event to a moment captured earlier.
    @inline(__always)
    public static func record(_ request: Int, _ name: String, _ detail: @autoclosure () -> String = "", at time: UInt64? = nil) {
        guard enabled else { return }
        append(Event(request: request, name: name, detail: detail(), nanoseconds: time ?? now()))
    }

    private static func append(_ event: Event) {
        state.withLock { state in
            if state.events.count < capacity { state.events.append(event) }
        }
        if printsSummaries, event.name == "panelDraw" || event.name == "superseded" {
            print(timeline(for: event.request))
        }
    }

    public static func reset() {
        state.withLock { $0 = State() }
    }

    public static func events(for request: Int? = nil) -> [Event] {
        state.withLock { state in
            request.map { id in state.events.filter { $0.request == id } } ?? state.events
        }
    }

    // MARK: - Drawing

    /// The controller says the popup for `request` was just updated; the panel's next `draw` closes the request.
    public static func expectDraw(for request: Int) {
        guard enabled else { return }
        state.withLock { $0.drawPending = request }
    }

    /// Called from the panel view's `draw(_:)`.
    @inline(__always)
    public static func noteDraw() {
        guard enabled else { return }
        let request = state.withLock { state -> Int? in
            defer { state.drawPending = nil }
            return state.drawPending
        }
        if let request { record(request, "panelDraw") }
    }

    // MARK: - Reading a timeline

    /// The time of the first event named `name` for `request`, in nanoseconds since the request's earliest event.
    public static func offset(of name: String, for request: Int) -> Double? {
        let events = events(for: request)
        guard let origin = events.map(\.nanoseconds).min(), let event = events.first(where: { $0.name == name }) else { return nil }
        return Double(event.nanoseconds - origin) / 1e6
    }

    /// One line per request: each event with its offset in milliseconds from the first.
    public static func timeline(for request: Int) -> String {
        let events = events(for: request).sorted { $0.nanoseconds < $1.nanoseconds }
        guard let origin = events.first?.nanoseconds else { return "completion #\(request): no events" }
        let parts = events.map { event -> String in
            let milliseconds = Double(event.nanoseconds - origin) / 1e6
            let detail = event.detail.isEmpty ? "" : "(\(event.detail))"
            return String(format: "%@%@ %.2f", event.name, detail, milliseconds)
        }
        return "completion #\(request): " + parts.joined(separator: " → ")
    }
}
