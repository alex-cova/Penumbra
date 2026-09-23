import CryptoKit
import Foundation

/// Persists a decoded ``JavaGradleProjectModel`` on disk so Umbra can wire up indexed dependency
/// shards immediately on reopen without waiting for Gradle. Deliberately stored under Application
/// Support (not `JavaIndexPaths`'s Caches root) so entries survive index-format bumps, mirroring
/// ``GradleTrustStore``.
public struct GradleProjectModelCache: Sendable {
    private struct Metadata: Codable {
        var fingerprint: GradleBuildFingerprint
        var cachedAt: Date
    }

    public let cacheRoot: URL

    public init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
    }

    /// `~/Library/Application Support/<bundleID>/gradle-models/`
    public static func defaultCacheRoot(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.penumbra.umbra"
    ) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("gradle-models", isDirectory: true)
    }

    public static func fingerprint(projectRoot: URL) -> GradleBuildFingerprint {
        GradleBuildFingerprintCollector.collect(projectRoot: projectRoot)
    }

    /// Returns a cached model when `meta.json`'s fingerprint still matches the project on disk and
    /// the bundled init script format version hasn't changed.
    public func loadIfValid(projectRoot: URL) -> JavaGradleProjectModel? {
        let directory = projectDirectory(for: projectRoot)
        guard let metadata = loadMetadata(from: directory) else { return nil }
        guard metadata.fingerprint.scriptFormatVersion == GradleProjectModelScript.formatVersion else {
            return nil
        }
        let current = GradleBuildFingerprintCollector.collect(projectRoot: projectRoot)
        guard metadata.fingerprint == current else { return nil }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("model.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(JavaGradleProjectModel.self, from: data)
    }

    public func store(projectRoot: URL, model: JavaGradleProjectModel) {
        let directory = projectDirectory(for: projectRoot)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = Metadata(
            fingerprint: GradleBuildFingerprintCollector.collect(projectRoot: projectRoot),
            cachedAt: Date()
        )
        guard let metaData = try? JSONEncoder().encode(metadata),
              let modelData = try? JSONEncoder().encode(model) else {
            return
        }
        try? metaData.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
        try? modelData.write(to: directory.appendingPathComponent("model.json"), options: .atomic)
    }

    public func invalidate(projectRoot: URL) {
        try? FileManager.default.removeItem(at: projectDirectory(for: projectRoot))
    }

    private func projectDirectory(for projectRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(Self.sha256(projectRoot.standardizedFileURL.path), isDirectory: true)
    }

    private func loadMetadata(from directory: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private static func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
