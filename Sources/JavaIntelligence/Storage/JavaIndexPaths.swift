import Foundation
import CryptoKit

/// Resolves where index shards live on disk: `~/Library/Caches/<bundleID>/JavaIndex/v<formatVersion>/`,
/// with JDK and JAR shards shared across every project (like IntelliJ's shared indexes) and one
/// subdirectory per project root for source-file stamps.
public struct JavaIndexPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The default location, versioned by ``JavaIndexShardWriter/formatVersion`` so a format change
    /// starts from an empty cache instead of trying (and failing) to read stale shards.
    public static func `default`(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.penumbra.umbra") -> JavaIndexPaths {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let root = base
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("JavaIndex")
            .appendingPathComponent("v\(JavaIndexShardWriter.formatVersion)")
        return JavaIndexPaths(root: root)
    }

    public func jdkShard(_ installation: JDKInstallation, kind: String) -> URL {
        root.appendingPathComponent("jdk-\(sha256(installation.cacheKey))-\(kind).idx")
    }

    public func jarShard(_ jarURL: URL) -> URL {
        root.appendingPathComponent("jar-\(sha256(jarURL.path)).idx")
    }

    public func projectDirectory(rootHash: String) -> URL {
        root.appendingPathComponent("projects").appendingPathComponent(rootHash)
    }

    public func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
