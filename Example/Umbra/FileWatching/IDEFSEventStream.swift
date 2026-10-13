import CoreServices
import Foundation

/// The one FSEvents stream type in Umbra. Only ``IDEProjectWatcher`` creates it: everything else
/// that reacts to disk changes subscribes to the watcher's batches instead of watching on its own.
///
/// Watches any number of directory trees at file granularity (`kFSEventStreamCreateFlagFileEvents`)
/// and yields each reported path that `pathFilter` accepts. Paths come back canonicalized
/// (`realpath`: `/private/var/…` for `/var/…`), as FSEvents reports them. Removed, created and
/// modified are not told apart: every consumer compares content, so a path is all it needs.
final class IDEFSEventStream: @unchecked Sendable {
    /// The directories watched, canonicalized.
    let roots: [String]
    private let latency: CFTimeInterval
    private let pathFilter: @Sendable (String) -> Bool
    /// Guards `streamRef` and `isStopped`: `start()` and `stop()` run on different tasks (a window
    /// that closes right after opening a project stops a stream that is still starting), and a
    /// stream released between its creation and `FSEventStreamStart` crashes.
    private let lock = NSLock()
    private var streamRef: FSEventStreamRef?
    private var isStopped = false
    private let continuation: AsyncStream<String>.Continuation
    let paths: AsyncStream<String>

    init(roots: [String], latency: CFTimeInterval = 0.3, pathFilter: @escaping @Sendable (String) -> Bool) {
        self.roots = roots
        self.latency = latency
        self.pathFilter = pathFilter
        var capturedContinuation: AsyncStream<String>.Continuation!
        self.paths = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation
    }

    deinit {
        if let streamRef {
            FSEventStreamStop(streamRef)
            FSEventStreamInvalidate(streamRef)
            FSEventStreamRelease(streamRef)
        }
    }

    func start() {
        lock.withLock { startLocked() }
    }

    private func startLocked() {
        guard streamRef == nil, !isStopped, !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let createFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, createFlags
        ) else {
            return
        }
        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        let stream: FSEventStreamRef? = lock.withLock {
            isStopped = true
            defer { streamRef = nil }
            return streamRef
        }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // Also when no stream was ever attached: a stopped stream has no more paths to deliver.
        continuation.finish()
    }

    /// `realpath` when the path exists, else its parent's `realpath` plus the name, else the path
    /// standardized. This is the form FSEvents reports, which `resolvingSymlinksInPath()` is not
    /// (it turns `/private/var` back into `/var`).
    static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().path
        if let resolved = realpath(parent, nil) {
            defer { free(resolved) }
            return (String(cString: resolved) as NSString).appendingPathComponent(url.lastPathComponent)
        }
        return url.path
    }

    private static let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPathsRaw, _, _ in
        guard let clientCallBackInfo else { return }
        let stream = Unmanaged<IDEFSEventStream>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
        guard let paths = unsafeBitCast(eventPathsRaw, to: CFArray.self) as? [String] else { return }
        for index in 0..<min(numEvents, paths.count) where stream.pathFilter(paths[index]) {
            stream.continuation.yield(paths[index])
        }
    }
}
