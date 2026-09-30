import Foundation

/// A small, file-backed set of Gradle project roots the user has trusted (or explicitly declined)
/// to run build scripts for. Gradle build scripts execute arbitrary code the moment any task is
/// invoked, wrapper or not, so ``GradleCommandRunner`` refuses to run anything for a root that
/// isn't in here (mirroring IntelliJ's own "Trust this project?" gate).
///
/// Deliberately independent of ``JavaIndexPaths``: that root lives under `~/Library/Caches` and is
/// versioned by the shard format, so trust decisions stored there would silently reset whenever the
/// index format bumps. Callers should point `storeURL` at a stable, non-cache location instead
/// (Umbra uses `~/Library/Application Support/<bundle id>/gradle-trust.json`, alongside
/// `session.json`).
public final class GradleTrustStore: @unchecked Sendable {
    private struct Snapshot: Codable {
        var trusted: [String] = []
        var declined: [String] = []
    }

    private let storeURL: URL
    private let lock = NSLock()
    private var trusted: Set<String>
    private var declined: Set<String>
    private var stamp: FileChangeStamp

    public init(storeURL: URL) {
        self.storeURL = storeURL
        let loaded = Self.load(storeURL)
        self.trusted = loaded?.trusted ?? []
        self.declined = loaded?.declined ?? []
        self.stamp = FileChangeStamp(url: storeURL)
    }

    /// Nil when the file is missing or unreadable.
    private static func load(_ url: URL) -> (trusted: Set<String>, declined: Set<String>)? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        return (Set(snapshot.trusted), Set(snapshot.declined))
    }

    /// Another window's store or another process may have written the file since this one read it:
    /// a trust decision made there must count here, and a write here must not drop it. A file that
    /// cannot be read keeps what is in memory. Caller must hold `lock`.
    private func reloadIfChangedOnDisk() {
        guard stamp.hasChanged(at: storeURL) else { return }
        stamp.update(at: storeURL)
        guard let loaded = Self.load(storeURL) else { return }
        trusted = loaded.trusted
        declined = loaded.declined
    }

    public func isTrusted(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        return trusted.contains(key(for: url))
    }

    /// `true` if the user previously trusted this root, `false` if they previously declined it,
    /// `nil` if they've never been asked.
    public func decision(for url: URL) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        let k = key(for: url)
        if trusted.contains(k) { return true }
        if declined.contains(k) { return false }
        return nil
    }

    public func setTrusted(_ isTrusted: Bool, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        let k = key(for: url)
        if isTrusted {
            trusted.insert(k)
            declined.remove(k)
        } else {
            declined.insert(k)
            trusted.remove(k)
        }
        persist()
    }

    private func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Caller must hold `lock`.
    private func persist() {
        let snapshot = Snapshot(trusted: trusted.sorted(), declined: declined.sorted())
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
        stamp.update(at: storeURL)
    }
}
