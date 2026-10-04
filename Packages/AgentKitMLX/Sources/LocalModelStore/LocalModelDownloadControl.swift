import Foundation

/// Thrown when a download stops because the user tapped Pause. The checkpoint on disk holds resume state.
public struct LocalModelDownloadPaused: Error {}

/// Coordinates pause and cancel across the store and URLSession.
public final class LocalModelDownloadControl: Sendable {
    private struct State {
        var cancelled = false
        var pauseRequested = false
        var resumeData: Data?
        var downloadTask: URLSessionDownloadTask?
    }

    private let state = Mutex(State())

    public init() {}

    public var isPauseRequested: Bool {
        state.withLock { $0.pauseRequested }
    }

    public func registerTask(_ task: URLSessionDownloadTask) {
        state.withLock {
            $0.downloadTask = task
            $0.resumeData = nil
        }
    }

    public func clearTask() {
        state.withLock { $0.downloadTask = nil }
    }

    /// Pause an in-flight file (producing resume data) or mark a between-files pause.
    public func pause() async {
        let task = state.withLock { state -> URLSessionDownloadTask? in
            state.pauseRequested = true
            return state.downloadTask
        }
        guard let task else { return }
        let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            task.cancel(byProducingResumeData: { continuation.resume(returning: $0) })
        }
        state.withLock { $0.resumeData = data }
    }

    public func cancel() {
        state.withLock {
            $0.cancelled = true
            $0.downloadTask?.cancel()
        }
    }

    public func throwIfCancelled() throws {
        if state.withLock({ $0.cancelled }) { throw CancellationError() }
    }

    public func takeResumeData() -> Data? {
        state.withLock {
            $0.pauseRequested = false
            let data = $0.resumeData
            $0.resumeData = nil
            return data
        }
    }
}
