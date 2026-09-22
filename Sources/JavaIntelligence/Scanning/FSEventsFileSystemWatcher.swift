import CoreServices
import EditorIntelligence
import Foundation

/// Watches a directory tree with FSEvents and emits file changes as
/// `EditorIntelligence.FileSystemEvent`s. By default only `.java` paths are forwarded (what
/// `JavaIndexScheduler` re-indexes); pass `pathFilter` to watch a different set, such as Gradle
/// build scripts. Polling the whole tree every couple of seconds (the package's
/// `PollingFileSystemWatcher`) doesn't scale to a real project's source tree; FSEvents gets
/// kernel-level notifications instead.
///
/// FSEvents reports changes at file granularity (with `kFSEventStreamCreateFlagFileEvents`), but
/// doesn't distinguish create/modify from its flags as cleanly as one might like for a "was this
/// added, changed, or removed" answer -- a rename shows up as both a removal of the old path and a
/// creation of the new one, for instance. This watcher treats `ItemRemoved` (with the file no
/// longer on disk) as `.fileRemoved`, `ItemCreated` as `.fileAdded`, and anything else (content
/// modifications, renames landing on this path) as `.fileChanged`; callers that key off content
/// (as `JavaIndexScheduler`'s stamp comparison does) are unaffected by that imprecision either way.
public final class FSEventsFileSystemWatcher: FileSystemWatcher, @unchecked Sendable {
    private let root: URL
    private let latency: CFTimeInterval
    private let pathFilter: @Sendable (String) -> Bool
    private var streamRef: FSEventStreamRef?
    private let continuation: AsyncStream<FileSystemEvent>.Continuation
    public let events: AsyncStream<FileSystemEvent>

    /// `pathFilter` receives the absolute path FSEvents reported and decides whether it becomes an
    /// event. The default keeps the historical `.java`-only behavior.
    public init(
        root: URL,
        latency: CFTimeInterval = 0.3,
        pathFilter: @escaping @Sendable (String) -> Bool = { $0.hasSuffix(".java") }
    ) {
        self.root = root
        self.latency = latency
        self.pathFilter = pathFilter
        var capturedContinuation: AsyncStream<FileSystemEvent>.Continuation!
        self.events = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation
    }

    deinit {
        if let streamRef {
            FSEventStreamStop(streamRef)
            FSEventStreamInvalidate(streamRef)
            FSEventStreamRelease(streamRef)
        }
    }

    public func start() async {
        guard streamRef == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // FSEvents always reports paths canonicalized (symlinks resolved, e.g. macOS's
        // /var -> /private/var), so the root itself is resolved here too -- otherwise every
        // reported path would fail a caller's `hasPrefix`/equality check against the un-resolved
        // root they passed in.
        let pathsToWatch = [root.resolvingSymlinksInPath().path] as CFArray
        let createFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, createFlags
        ) else {
            return
        }
        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    public func stop() async {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
        continuation.finish()
    }

    private static let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPathsRaw, eventFlags, _ in
        guard let clientCallBackInfo else { return }
        let watcher = Unmanaged<FSEventsFileSystemWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
        guard let paths = unsafeBitCast(eventPathsRaw, to: CFArray.self) as? [String] else { return }
        for index in 0..<numEvents {
            guard index < paths.count else { break }
            let path = paths[index]
            guard watcher.pathFilter(path) else { continue }
            let url = URL(fileURLWithPath: path)
            let flags = eventFlags[index]
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0, !FileManager.default.fileExists(atPath: path) {
                watcher.continuation.yield(.fileRemoved(url))
            } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
                watcher.continuation.yield(.fileAdded(url))
            } else {
                watcher.continuation.yield(.fileChanged(url))
            }
        }
    }
}
