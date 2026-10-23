import EditorIntelligence
import Foundation

/// Reads a single `.java` file out of a JDK `src.zip` or a dependency `*-sources.jar` that is
/// already on disk. Nothing is downloaded. The file is copied under the index cache so the editor
/// can open it; that copy is not the JDK and must be shown read-only.
public enum JavaAttachedSources {
    public static func isExtractedSource(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains("attached-sources")
    }

    /// `jdkHome` is the JDK whose `lib/src.zip` matches a `.jdkModule` origin. `jar` is the binary
    /// jar of a `.jar` origin. `topLevel` is the outermost type, whose compilation unit holds any
    /// nested type.
    static func extract(
        jdkHome: URL?, module: String?, binaryJar: URL?, topLevel: JavaClassStub, cacheRoot: URL
    ) -> (url: URL, text: String)? {
        let relative = relativePath(packageName: topLevel.packageName, simpleName: topLevel.simpleName)
        if let module, let jdkHome {
            let archive = jdkHome.appendingPathComponent("lib/src.zip")
            let names = ["\(module)/\(relative)", relative]
            if let (entry, text) = read(archive: archive, names: names) {
                guard let url = write(text, archive: archive, entry: entry, cacheRoot: cacheRoot) else { return nil }
                return (url, text)
            }
        }
        if let binaryJar, let sources = sourcesJar(adjacentTo: binaryJar) {
            if let (entry, text) = read(archive: sources, names: [relative]) {
                guard let url = write(text, archive: sources, entry: entry, cacheRoot: cacheRoot) else { return nil }
                return (url, text)
            }
        }
        return nil
    }

    /// Copies one non-class entry of a dependency jar (`META-INF/MANIFEST.MF`, a properties file) under
    /// the cache so the editor can open it; like a source, the copy is shown read-only. Nothing is
    /// written again while the copy is the entry's size and no older than the jar.
    public static func extractResource(entry: String, from archive: URL, cacheRoot: URL) -> URL? {
        guard let zip = ZipArchiveCache.shared.archive(at: archive),
              let data = try? zip.data(for: entry) else { return nil }
        var destination = cacheRoot
            .appendingPathComponent("attached-sources", isDirectory: true)
            .appendingPathComponent(stableKey(archive.path), isDirectory: true)
            .appendingPathComponent("resources", isDirectory: true)
        let components = entry.split(separator: "/").filter { $0 != ".." && $0 != "." }
        guard !components.isEmpty else { return nil }
        for component in components { destination.appendPathComponent(String(component)) }
        if isCurrent(destination, size: data.count, archive: archive) { return destination }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    static func relativePath(packageName: String, simpleName: String) -> String {
        if packageName.isEmpty { return "\(simpleName).java" }
        return packageName.replacingOccurrences(of: ".", with: "/") + "/\(simpleName).java"
    }

    /// A `*-sources.jar` sitting next to `jar`, or one directory up in a sibling Gradle-cache hash
    /// directory (`.../version/<hash>/artifact.jar` beside `.../version/<other>/artifact-sources.jar`).
    public static func sourcesJar(adjacentTo jar: URL) -> URL? {
        let parent = jar.deletingLastPathComponent()
        if let found = firstSourcesJar(in: parent) { return found }
        let versionDirectory = parent.deletingLastPathComponent()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: versionDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for child in children {
            if let found = firstSourcesJar(in: child) { return found }
        }
        return nil
    }

    private static func firstSourcesJar(in directory: URL) -> URL? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        return urls.first { $0.lastPathComponent.hasSuffix("-sources.jar") }
    }

    private static func read(archive url: URL, names: [String]) -> (entry: String, text: String)? {
        guard let archive = ZipArchiveCache.shared.archive(at: url) else { return nil }
        for name in names {
            guard let data = try? archive.data(for: name), let text = String(data: data, encoding: .utf8) else { continue }
            return (name, text)
        }
        return nil
    }

    private static func write(_ text: String, archive: URL, entry: String, cacheRoot: URL) -> URL? {
        var destination = cacheRoot
            .appendingPathComponent("attached-sources", isDirectory: true)
            .appendingPathComponent(stableKey(archive.path), isDirectory: true)
        for component in entry.split(separator: "/") {
            destination.appendPathComponent(String(component))
        }
        if isCurrent(destination, size: text.utf8.count, archive: archive) { return destination }
        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: destination, atomically: true, encoding: .utf8)
            return destination
        } catch {
            return nil
        }
    }

    /// The copy from an earlier request, when it is the size of the entry and no older than the
    /// archive: writing it again would only touch a file the editor may have open.
    private static func isCurrent(_ destination: URL, size: Int, archive: URL) -> Bool {
        let fileManager = FileManager.default
        guard let copy = try? fileManager.attributesOfItem(atPath: destination.path),
              let copySize = copy[.size] as? Int, copySize == size,
              let copyDate = copy[.modificationDate] as? Date,
              let source = try? fileManager.attributesOfItem(atPath: archive.path),
              let sourceDate = source[.modificationDate] as? Date else { return false }
        return copyDate >= sourceDate
    }

    static func stableKey(_ path: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

public extension Document {
    /// A library's source or decompiled class opened for reading (External Libraries, Go to
    /// Definition). It is dependency code: navigation works on it, but nothing checks it, so no
    /// compiler run, inspection, syntax error or quick fix is produced for it.
    var isDependencySource: Bool {
        url.map(JavaAttachedSources.isExtractedSource) ?? false
    }
}
