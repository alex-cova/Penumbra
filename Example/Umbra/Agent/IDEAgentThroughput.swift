import Foundation

/// Output speed for the run in progress, and the last run's final speed once it ends.
///
/// Providers only report token counts when a turn finishes, so while text streams the count is
/// estimated from its length (about four characters per token) and replaced by the reported
/// total as turns complete. `nil` until the first measurable output; frozen at the end of the
/// run so the header keeps showing it. Both AI-mode conversations (Code and Chat) own one.
struct IDEAgentThroughput: Equatable {
    /// Tokens per second: live while streaming, the final speed after the run. `nil` when nothing
    /// measurable has arrived yet (the model is still thinking, or the run never produced text).
    private(set) var tokensPerSecond: Double?
    /// What the speed is measured over: output tokens and wall-clock seconds.
    private(set) var tokens = 0
    private(set) var seconds: TimeInterval = 0

    /// Armed at the run's start; cleared by `end()` so later refreshes cannot decay the frozen value.
    private var armedAt: Date?
    /// When the run's first streamed text arrived; the clock starts here, not at setup or model load.
    private var firstTokenAt: Date?
    /// Reported output tokens when the run began; usage arrives as a lifetime total.
    private var baseline = 0
    /// Reported output tokens produced by this run.
    private var outputTokens = 0
    /// Streamed characters this run, for the estimate before usage arrives.
    private var streamedChars = 0

    /// Characters per token for the streaming estimate.
    static let charsPerToken = 4.0
    /// Shorter than this is timer noise, not a speed.
    static let minElapsed: TimeInterval = 0.02

    mutating func begin(totalOutputTokens: Int, now: Date = Date()) {
        armedAt = now
        firstTokenAt = nil
        baseline = totalOutputTokens
        outputTokens = 0
        streamedChars = 0
        tokensPerSecond = nil
        tokens = 0
        seconds = 0
    }

    /// Counts streamed text toward the live estimate. Refreshing happens in the flush, so a fast
    /// model does not re-render the header per token.
    mutating func addStreamed(_ delta: String, now: Date = Date()) {
        guard armedAt != nil else { return }
        if firstTokenAt == nil { firstTokenAt = now }
        streamedChars += delta.count
    }

    mutating func noteUsage(totalOutputTokens: Int, now: Date = Date()) {
        guard armedAt != nil else { return }
        outputTokens = max(0, totalOutputTokens - baseline)
        refresh(now: now)
    }

    mutating func refresh(now: Date = Date()) {
        guard let armed = armedAt else { return }
        let elapsed = now.timeIntervalSince(firstTokenAt ?? armed)
        guard elapsed >= Self.minElapsed else { return }
        let estimated = max(outputTokens, Int(Double(streamedChars) / Self.charsPerToken))
        guard estimated > 0 else { return }
        tokens = estimated
        seconds = elapsed
        tokensPerSecond = Double(estimated) / elapsed
    }

    /// Freezes the last measured speed for display after the run.
    mutating func end() {
        armedAt = nil
        firstTokenAt = nil
    }

    mutating func reset() {
        self = Self()
    }

    /// "12 tokens in 0.8 s", or `nil` when nothing was measured.
    var summary: String? {
        guard tokensPerSecond != nil else { return nil }
        return "\(tokens) tokens in \(String(format: "%.1f", seconds)) s"
    }
}
