import Foundation

/// A file as it was in a past commit, written under the cache so an editor tab can show it
/// (Annotate Revision, Annotate Previous Revision). The path says where it came from, so blame of
/// such a tab runs at that revision, and `JavaAttachedSources.isInCache` (the `git-revisions`
/// component) makes the tab read-only and keeps analysis away from it.
///
/// `<cache>/git-revisions/<repository key>/<hash>/<path in the repository>`, with the repository's
/// root written once beside it (`<repository key>/root.txt`).
enum IDEGitRevisionFiles {
    struct Source: Equatable {
        let repositoryRoot: String
        let hash: String
        let relativePath: String
    }

    static var defaultCacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("git-revisions", isDirectory: true)
    }

    private static let rootFileName = "root.txt"

    static func repositoryKey(_ repositoryRoot: String) -> String {
        String(IDEBlamePresentation.stableHash(repositoryRoot), radix: 16)
    }

    /// Where the snapshot of `relativePath` at `hash` lives. Nil for a hash that is not hex or a
    /// path with nothing in it.
    static func snapshotURL(
        repositoryRoot: String, hash: String, relativePath: String, cacheRoot: URL = defaultCacheRoot
    ) -> URL? {
        guard isHash(hash) else { return nil }
        let components = relativePath.split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." }
        guard !components.isEmpty else { return nil }
        var url = cacheRoot
            .appendingPathComponent(repositoryKey(repositoryRoot), isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
        for component in components { url.appendPathComponent(component) }
        return url
    }

    /// Writes `data` as the snapshot and returns its URL. An existing copy is kept: a commit never changes.
    static func write(
        _ data: Data, repositoryRoot: String, hash: String, relativePath: String, cacheRoot: URL = defaultCacheRoot
    ) -> URL? {
        guard let url = snapshotURL(repositoryRoot: repositoryRoot, hash: hash, relativePath: relativePath, cacheRoot: cacheRoot) else { return nil }
        let manager = FileManager.default
        do {
            let keyDirectory = cacheRoot.appendingPathComponent(repositoryKey(repositoryRoot), isDirectory: true)
            try manager.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
            try Data(repositoryRoot.utf8).write(to: keyDirectory.appendingPathComponent(rootFileName), options: .atomic)
            if !manager.fileExists(atPath: url.path) {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            return url
        } catch {
            return nil
        }
    }

    /// Where `url` came from, or nil when it is not a snapshot this cache wrote.
    static func source(for url: URL, cacheRoot: URL = defaultCacheRoot) -> Source? {
        let prefix = cacheRoot.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > prefix.count + 2, Array(components.prefix(prefix.count)) == prefix else { return nil }
        let key = components[prefix.count]
        let hash = components[prefix.count + 1]
        let rest = components.dropFirst(prefix.count + 2)
        guard isHash(hash), !rest.isEmpty,
              let rootData = try? Data(contentsOf: cacheRoot.appendingPathComponent(key).appendingPathComponent(rootFileName)),
              let root = String(data: rootData, encoding: .utf8), repositoryKey(root) == key else { return nil }
        return Source(repositoryRoot: root, hash: hash, relativePath: rest.joined(separator: "/"))
    }

    static func isSnapshot(_ url: URL, cacheRoot: URL = defaultCacheRoot) -> Bool {
        source(for: url, cacheRoot: cacheRoot) != nil
    }

    private static func isHash(_ hash: String) -> Bool {
        (7...64).contains(hash.count) && hash.allSatisfy(\.isHexDigit)
    }
}
