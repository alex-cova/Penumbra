import Foundation

/// A bounded cache of parsed POMs, shared by every window. A release POM does not change, so it is
/// kept in preference to a SNAPSHOT or a project POM, the same idea as
/// ``JavaJarCachePolicy/isImmutableArtifact``.
public final class MavenPOMStore: @unchecked Sendable {
    public static let shared = MavenPOMStore()

    private let lock = NSLock()
    private var entries: [String: MavenPOM] = [:]
    private var order: [String] = []
    private let limit: Int

    public init(limit: Int = 256) {
        self.limit = limit
    }

    public func pom(at file: URL) throws -> MavenPOM {
        let key = file.standardizedFileURL.path
        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let parsed = try MavenPOMParser.parse(contentsOf: file)
        lock.lock()
        entries[key] = parsed
        order.removeAll { $0 == key }
        order.append(key)
        evictIfNeeded()
        lock.unlock()
        return parsed
    }

    /// Drops project POMs so the next read sees a file the user just saved. Release POMs stay.
    public func invalidateProjectPOMs() {
        lock.lock()
        let stale = order.filter { !isReleaseArtifact($0) }
        for key in stale { entries[key] = nil }
        order.removeAll { stale.contains($0) }
        lock.unlock()
    }

    private func evictIfNeeded() {
        while entries.count > limit, let key = order.first(where: { !isReleaseArtifact($0) }) ?? order.first {
            entries[key] = nil
            order.removeAll { $0 == key }
        }
    }

    private func isReleaseArtifact(_ path: String) -> Bool {
        let version = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return !version.isEmpty && !version.contains("SNAPSHOT") && path.contains(".m2/repository")
    }
}
