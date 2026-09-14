import Foundation

/// A lightweight polling-based file-system watcher.
///
/// Replaced with a native FSEvents implementation in a later phase. This watcher is an actor so
/// snapshot mutation and the polling loop share isolation; `events` is `nonisolated` because
/// ``EventBus`` is independently thread-safe.
public actor PollingFileSystemWatcher: FileSystemWatcher {
    public let url: URL
    public let interval: TimeInterval
    public nonisolated var events: AsyncStream<FileSystemEvent> { eventBus.events }

    private nonisolated let eventBus = EventBus<FileSystemEvent>()
    private var task: Task<Void, Never>?
    private var snapshot: [URL: Date] = [:]

    public init(url: URL, interval: TimeInterval = 2.0) {
        self.url = url
        self.interval = interval
    }

    deinit {
        task?.cancel()
    }

    public func start() {
        task?.cancel()
        let root = url
        let pollInterval = interval
        task = Task {
            while !Task.isCancelled {
                self.scan(root: root)
                if #available(macOS 13.0, iOS 16.0, *) {
                    try? await Task.sleep(for: .seconds(pollInterval))
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func scan(root: URL) {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var newSnapshot: [URL: Date] = [:]
        while let fileURL = enumerator?.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else {
                continue
            }
            newSnapshot[fileURL] = date
            if let oldDate = snapshot[fileURL] {
                if oldDate != date {
                    eventBus.send(.fileChanged(fileURL))
                }
            } else {
                eventBus.send(.fileAdded(fileURL))
            }
        }
        for (oldURL, _) in snapshot where newSnapshot[oldURL] == nil {
            eventBus.send(.fileRemoved(oldURL))
        }
        snapshot = newSnapshot
    }
}
