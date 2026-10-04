import Foundation

public struct LocalModelDownloadProgress: Hashable, Sendable {
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double?
    public var currentFile: String?
    public var isPaused = false

    public init(
        bytesDownloaded: Int64, totalBytes: Int64, bytesPerSecond: Double? = nil, currentFile: String? = nil, isPaused: Bool = false
    ) {
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.currentFile = currentFile
        self.isPaused = isPaused
    }

    /// `nil` when the Hub did not report sizes, so the UI can show an indeterminate bar.
    public var fractionCompleted: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(bytesDownloaded) / Double(totalBytes))
    }

    public var estimatedTimeRemaining: TimeInterval? {
        guard !isPaused, let bytesPerSecond, bytesPerSecond > 0, totalBytes > bytesDownloaded else { return nil }
        return Double(totalBytes - bytesDownloaded) / bytesPerSecond
    }

    /// e.g. "18.2 MB/s"
    public var speedText: String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let rate = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond.rounded()), countStyle: .file)
        return "\(rate)/s"
    }

    /// e.g. "about 4 min left"
    public var etaText: String? {
        guard let seconds = estimatedTimeRemaining, seconds.isFinite, seconds >= 1 else { return nil }
        return "about \(Self.formatDuration(seconds)) left"
    }

    /// e.g. "124.5 MB of 512 MB · 18.2 MB/s"
    public var detailText: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
        var text = downloaded
        if totalBytes > 0 {
            text = "\(downloaded) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
        }
        if isPaused {
            text += " · Paused"
        } else if let speedText {
            text += " · \(speedText)"
        }
        if let etaText, !isPaused { text += " · \(etaText)" }
        return text
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "\(Int(seconds.rounded())) sec"
    }
}

/// Aggregates bytes across every file of a repository into one throttled, speed-smoothed stream.
///
/// Deliberately local to LocalModels: the Containers tracker is welded to that feature's progress type.
struct LocalModelTransferTracker: Sendable {
    let totalBytes: Int64
    var currentFile: String?

    /// Finished files are counted by their real on-disk size; only the file in flight relies on
    /// URLSession's delegate, which is not guaranteed to report every byte (tiny files can skip it).
    private var completedBytes: Int64 = 0
    private var currentFileBytes: Int64 = 0
    var bytesDownloaded: Int64 { completedBytes + currentFileBytes }

    private var lastEmitAt: Date?
    private var windowStartedAt: Date?
    private var windowBytes: Int64 = 0
    private var bytesPerSecond: Double?

    init(totalBytes: Int64) {
        self.totalBytes = max(0, totalBytes)
    }

    mutating func add(_ bytes: Int64) {
        currentFileBytes += max(0, bytes)
    }

    /// Replaces the delegate's running count for the file just finished with its actual size.
    mutating func completeFile(size: Int64) {
        completedBytes += max(0, size)
        currentFileBytes = 0
    }

    mutating func restore(completedBytes: Int64, currentFile: String?) {
        self.completedBytes = max(0, completedBytes)
        self.currentFileBytes = 0
        self.currentFile = currentFile
        self.lastEmitAt = nil
        self.windowStartedAt = nil
        self.windowBytes = 0
        self.bytesPerSecond = nil
    }

    /// Returns a snapshot at most once per `minInterval`. Pass `force` for the final 100% update.
    mutating func snapshot(at date: Date = .now, minInterval: TimeInterval = 0.5, force: Bool = false) -> LocalModelDownloadProgress? {
        updateSpeed(at: date)
        if !force {
            guard bytesDownloaded > 0 else { return nil }
            if let lastEmitAt, date.timeIntervalSince(lastEmitAt) < minInterval { return nil }
        }
        lastEmitAt = date
        return LocalModelDownloadProgress(
            bytesDownloaded: bytesDownloaded, totalBytes: totalBytes,
            bytesPerSecond: bytesPerSecond, currentFile: currentFile)
    }

    private mutating func updateSpeed(at date: Date) {
        guard let start = windowStartedAt else {
            windowStartedAt = date
            windowBytes = bytesDownloaded
            return
        }
        let elapsed = date.timeIntervalSince(start)
        guard elapsed >= 0.25 else { return }
        let instant = Double(max(0, bytesDownloaded - windowBytes)) / elapsed
        bytesPerSecond = bytesPerSecond.map { $0 * 0.65 + instant * 0.35 } ?? instant
        windowStartedAt = date
        windowBytes = bytesDownloaded
    }
}

/// Thread-safe wrapper: URLSession reports bytes on its own queue.
final class LocalModelTransferMeter: Sendable {
    private let tracker: Mutex<LocalModelTransferTracker>

    init(totalBytes: Int64) {
        tracker = Mutex(LocalModelTransferTracker(totalBytes: totalBytes))
    }

    func add(_ bytes: Int64) -> LocalModelDownloadProgress? {
        tracker.withLock {
            $0.add(bytes)
            return $0.snapshot()
        }
    }

    func begin(file: String) {
        tracker.withLock { $0.currentFile = file }
    }

    func completeFile(size: Int64) {
        tracker.withLock { $0.completeFile(size: size) }
    }

    func restore(completedBytes: Int64, currentFile: String?) {
        tracker.withLock {
            $0.restore(completedBytes: completedBytes, currentFile: currentFile)
        }
    }

    func final() -> LocalModelDownloadProgress {
        tracker.withLock { $0.snapshot(force: true)! }
    }
}
