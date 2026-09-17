import Foundation

/// Ranks candidate files for a quick-open (go-to-file) palette by fuzzy-matching against each
/// file's path relative to `root`, via ``FuzzyMatcher``.
public enum QuickOpenFileRanker {
    public static func rank(query: String, files: [URL], root: URL?, limit: Int) -> [URL] {
        let rootPath = root?.path
        return FuzzyMatcher.ranked(query: query, items: files, key: { relativePath(for: $0, rootPath: rootPath) }, limit: limit)
    }

    private static func relativePath(for url: URL, rootPath: String?) -> String {
        guard let rootPath else { return url.path }
        let normalizedRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if url.path.hasPrefix(normalizedRoot) {
            return String(url.path.dropFirst(normalizedRoot.count))
        }
        return url.lastPathComponent
    }
}
