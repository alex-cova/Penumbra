import Foundation

/// What the agent is told about the files it just changed: the editor's own errors in them. Not a
/// build (`diagnostics` and `gradle` are for that), only what the editor already knows a moment
/// after the edit, so a syntax slip or an obvious type error is seen in the same step.
enum IDEAgentEditProblems {
    struct Row: Equatable {
        var path: String
        var line: Int
        var message: String
    }

    /// How long the host waits for the editor to analyse the new text of an open file.
    static let timeout: TimeInterval = 1.5
    static let maxRows = 5
    static let maxMessageLength = 200

    /// `nil` when there is nothing to say: no errors, or the editor had not analysed the new text yet
    /// (an older result would describe the text before the edit).
    static func note(errors: [Row], analysed: Bool) -> String? {
        guard analysed, !errors.isEmpty else { return nil }
        var lines = [
            "[Editor] \(errors.count) error\(errors.count == 1 ? "" : "s") in the files you just changed, from the editor's own analysis (not a build; call diagnostics to compile):",
        ]
        for row in errors.prefix(maxRows) {
            let message = row.message.replacingOccurrences(of: "\n", with: " ")
            lines.append("\(row.path):\(row.line): \(message.count > maxMessageLength ? String(message.prefix(maxMessageLength)) + "…" : message)")
        }
        if errors.count > maxRows { lines.append("… and \(errors.count - maxRows) more.") }
        return lines.joined(separator: "\n")
    }

    /// Polls `ready` until it holds or `timeout` passes; returns whether it held.
    @MainActor
    static func wait(timeout: TimeInterval, interval: Duration = .milliseconds(50), _ ready: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !ready() {
            if ContinuousClock.now >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: interval)
        }
        return true
    }
}
