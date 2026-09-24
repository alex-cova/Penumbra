import Foundation

/// Development-only local readout. Off unless `PENUMBRA_PERFORMANCE_DASHBOARD=1`.
///
/// Rendering returns a string. It does not open a socket, start a URL session, or write a file.
public enum EditorPerformanceDashboard {
    public static let switchEnvironmentVariable = "PENUMBRA_PERFORMANCE_DASHBOARD"
    public static let pathEnvironmentVariable = "PENUMBRA_PERFORMANCE_DASHBOARD_PATH"

    /// The readout path never performs network access.
    public static let performsNetworkAccess = false

    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[switchEnvironmentVariable] == "1"
    }

    public static func render(
        frameSeconds: Double,
        textMutationSeconds: Double,
        incrementalParseSeconds: Double,
        completionSeconds: Double,
        diagnosticsSeconds: Double,
        indexQuerySeconds: Double,
        mainThreadSeconds: Double,
        droppedFrames: Int,
        memoryBytes: UInt64
    ) -> String {
        """
        Editor Performance

        Frame:                 \(formatMilliseconds(frameSeconds))
        Text Mutation:         \(formatMilliseconds(textMutationSeconds))
        Incremental Parse:     \(formatMilliseconds(incrementalParseSeconds))
        Completion:            \(formatMilliseconds(completionSeconds))
        Diagnostics:           \(formatMilliseconds(diagnosticsSeconds))
        Index Query:           \(formatMilliseconds(indexQuerySeconds))
        Main Thread:           \(formatMilliseconds(mainThreadSeconds))
        Dropped Frames:        \(droppedFrames)
        Memory:                \(formatMegabytes(memoryBytes))
        """
    }

    private static func formatMilliseconds(_ seconds: Double) -> String {
        String(format: "%.3f ms", seconds * 1_000)
    }

    private static func formatMegabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
