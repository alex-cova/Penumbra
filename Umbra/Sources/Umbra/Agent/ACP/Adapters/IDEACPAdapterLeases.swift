import Foundation

/// Which adapter versions a running ACP process is using. A version with a lease is never
/// removed or replaced on disk, so a chat that is mid-conversation keeps its executable even
/// while a newer version is activated for new chats.
///
/// The counts cover this Umbra's own agents. A lease taken with the version's folder also holds a
/// shared `flock` on `adapters/<id>/locks/version-<v>`, which the store's removal takes
/// exclusively, so another Umbra process cannot remove or replace a version that is running
/// here either. The kernel drops the lock when the process dies, so a crash leaves nothing held.
final class IDEACPAdapterLeases: @unchecked Sendable {
    static let shared = IDEACPAdapterLeases()

    final class Token: @unchecked Sendable {
        private weak var owner: IDEACPAdapterLeases?
        private let key: String
        private let lock = NSLock()
        private var released = false
        private let fileLock: IDEACPFileLock?

        fileprivate init(owner: IDEACPAdapterLeases, key: String, fileLock: IDEACPFileLock?) {
            self.owner = owner
            self.key = key
            self.fileLock = fileLock
        }

        func release() {
            let already = lock.withLock { () -> Bool in
                defer { released = true }
                return released
            }
            if !already {
                fileLock?.release()
                owner?.drop(key)
            }
        }

        deinit { release() }
    }

    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    private static func key(_ adapterID: String, _ version: String) -> String { "\(adapterID)@\(version)" }

    /// `versionDirectory`, when it is an installed version (`…/<id>/versions/<v>`), also takes the
    /// cross-process lock. It waits while another process is removing that version; the caller
    /// verifies the files after, so a version removed meanwhile is refused, not run.
    func acquire(adapterID: String, version: String, versionDirectory: URL? = nil) -> Token {
        let key = Self.key(adapterID, version)
        lock.withLock { counts[key, default: 0] += 1 }
        var fileLock: IDEACPFileLock?
        if let versionDirectory, let url = IDEACPAdapterStore.versionLockURL(forVersionDirectory: versionDirectory) {
            fileLock = IDEACPFileLock(url: url, exclusive: false, wait: true)
        }
        return Token(owner: self, key: key, fileLock: fileLock)
    }

    fileprivate func drop(_ key: String) {
        lock.withLock {
            let next = (counts[key] ?? 1) - 1
            if next <= 0 { counts.removeValue(forKey: key) } else { counts[key] = next }
        }
    }

    func count(adapterID: String, version: String) -> Int {
        lock.withLock { counts[Self.key(adapterID, version)] ?? 0 }
    }

    func isLeased(adapterID: String, version: String) -> Bool {
        count(adapterID: adapterID, version: version) > 0
    }

    func leasedVersions(adapterID: String) -> Set<String> {
        let prefix = "\(adapterID)@"
        return lock.withLock {
            Set(counts.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        }
    }

    func totalCount(adapterID: String) -> Int {
        let prefix = "\(adapterID)@"
        return lock.withLock { counts.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +) }
    }
}

/// An `flock` on a file, held until `release()` or deinit. Locks are per open file, so two
/// holders in one process conflict just as two processes do, and a dead process holds nothing.
final class IDEACPFileLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let url: URL
    private let removeOnRelease: Bool

    /// Nil when the file cannot be opened or, with `wait: false`, someone else holds a
    /// conflicting lock.
    init?(url: URL, exclusive: Bool, wait: Bool, removeOnRelease: Bool = false) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var operation = exclusive ? LOCK_EX : LOCK_SH
        if !wait { operation |= LOCK_NB }
        var result: Int32
        repeat { result = flock(fd, operation) } while result != 0 && errno == EINTR
        guard result == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
        self.url = url
        self.removeOnRelease = removeOnRelease
    }

    func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            if removeOnRelease { unlink(url.path) }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }

    /// True when some open file (this process or another) holds a lock on `url` that an
    /// exclusive lock would wait for. A missing file is not held.
    static func isHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
