import Foundation

/// Where the classes of a decompiled tab live: the jar it came out of, or the directory of compiled
/// classes (`build/classes/java/main`) it sits in. A reference search reads every class of it.
public enum JavaClassContainer: Hashable, Sendable {
    case archive(URL)
    case directory(URL)

    /// Entry names of every class (`a/b/C.class`, inner classes included), sorted. Multi-release
    /// copies under `META-INF/versions/` are left out.
    public func classEntries(limit: Int = 200_000) -> [String] {
        switch self {
        case .archive(let url):
            guard let archive = ZipArchiveCache.shared.archive(at: url) else { return [] }
            return archive.entries.map(\.name)
                .filter { $0.hasSuffix(".class") && !$0.hasPrefix("META-INF/") && !$0.hasSuffix("module-info.class") }
                .sorted()
        case .directory(let root):
            let base = root.standardizedFileURL.path
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }
            var names: [String] = []
            for case let url as URL in walker where url.pathExtension == "class" {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                names.append(String(path.dropFirst(base.count + 1)))
                if names.count >= limit { break }
            }
            return names.sorted()
        }
    }

    public func data(for entry: String) -> Data? {
        switch self {
        case .archive(let url):
            return ZipArchiveCache.shared.archive(at: url).flatMap { try? $0.data(for: entry) }
        case .directory(let root):
            guard !entry.split(separator: "/").contains("..") else { return nil }
            return try? Data(contentsOf: root.appendingPathComponent(entry), options: .mappedIfSafe)
        }
    }

    public func entry(forInternalName name: String) -> String { name + ".class" }

    public func contains(internalName name: String) -> Bool {
        data(for: entry(forInternalName: name)) != nil
    }

    /// Changes whenever the container's bytes do, for caches.
    public var stamp: String {
        let path: String
        switch self {
        case .archive(let url), .directory(let url): path = url.standardizedFileURL.path
        }
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return "\(path)|\(date?.timeIntervalSince1970 ?? 0)"
    }

    /// The container for a class file the user opened. A copy under the index cache belongs to
    /// whichever of `archives` it was extracted from; any other `.class` belongs to the directory
    /// that is the root of its package (`build/classes/java/main` for `com/acme/Foo.class`).
    public static func container(
        forClassFile url: URL, archives: [URL], classData: @autoclosure () -> Data?
    ) -> JavaClassContainer? {
        if let archive = JavaAttachedSources.archive(forExtractedCopy: url, among: archives) {
            return .archive(archive.standardizedFileURL)
        }
        guard !JavaAttachedSources.isInCache(url) else { return nil }
        guard let data = classData(), let parsed = JavaBytecodeReader.parse(data, includeBodies: false) else { return nil }
        var root = url.standardizedFileURL.deletingLastPathComponent()
        for _ in parsed.name.split(separator: "/").dropLast() { root.deleteLastPathComponent() }
        return .directory(root)
    }
}

extension JavaAttachedSources {
    /// The archive in `archives` that `url` (a class or resource under `attached-sources`) was
    /// extracted from. The folder under the cache is a hash of the archive's path.
    public static func archive(forExtractedCopy url: URL, among archives: [URL]) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard let marker = components.firstIndex(of: "attached-sources"), marker + 1 < components.count else { return nil }
        let key = components[marker + 1]
        return archives.first { stableKey($0.standardizedFileURL.path) == key }
    }
}
