import Foundation

/// The run configurations a project shares: one JSON file each in
/// `<project>/.umbra/runConfigurations/`, so they can be committed.
///
/// A file is `{"version": 1, "configuration": {…}}`. Paths inside the project are written relative
/// to it and resolved again on load, so a checkout that moves still works; the JDK a configuration
/// names is left out, since a path to a JDK means nothing on another machine. Files are read when
/// they change on disk, so an edit by hand (or a `git pull`) shows up at the next read.
public final class JavaProjectRunConfigurationFolder: @unchecked Sendable {
    public static let relativePath = ".umbra/runConfigurations"

    private struct File: Codable {
        var version = 1
        var configuration: JavaRunConfiguration
    }

    private struct Cached {
        var date: Date?
        var configuration: JavaRunConfiguration?
    }

    public let root: URL
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]
    /// File name (without the directory) of each configuration, as of the last read.
    private var names: [UUID: String] = [:]

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var directory: URL {
        root.appendingPathComponent(Self.relativePath, isDirectory: true)
    }

    /// Every configuration in the folder, ordered by file name. A file that is not valid, or that
    /// repeats the id of an earlier one, is skipped.
    public func configurations() -> [JavaRunConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    /// Writes `configuration` (renaming its file when its name changed). The file is created, with
    /// the folder, when it does not exist.
    public func save(_ configuration: JavaRunConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        _ = read()
        var stored = configuration.mappingPaths(relativize)
        stored.storeAsProjectFile = true
        stored.isTemporary = false
        stored.jdkHome = nil
        let previousName = names[configuration.id]
        let fileName = fileName(for: stored, keeping: previousName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(File(configuration: stored)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        if let previousName, previousName != fileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previousName))
            cache[previousName] = nil
        }
        names[configuration.id] = fileName
        cache[fileName] = Cached(date: Self.modificationDate(of: url), configuration: stored.mappingPaths(resolve))
    }

    public func delete(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        _ = read()
        guard let name = names[id] else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        cache[name] = nil
        names[id] = nil
    }

    // MARK: - Reading

    /// Caller must hold `lock`.
    private func read() -> [JavaRunConfiguration] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let files = urls.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var seenFiles = Set<String>()
        var seenIDs = Set<UUID>()
        var result: [JavaRunConfiguration] = []
        var newNames: [UUID: String] = [:]
        for url in files {
            let name = url.lastPathComponent
            seenFiles.insert(name)
            let date = Self.modificationDate(of: url)
            if cache[name]?.date != date || cache[name] == nil {
                cache[name] = Cached(date: date, configuration: load(url))
            }
            guard var configuration = cache[name]?.configuration, seenIDs.insert(configuration.id).inserted else { continue }
            configuration.storeAsProjectFile = true
            configuration.isTemporary = false
            result.append(configuration)
            newNames[configuration.id] = name
        }
        for name in cache.keys where !seenFiles.contains(name) { cache[name] = nil }
        names = newNames
        return result
    }

    private func load(_ url: URL) -> JavaRunConfiguration? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return file.configuration.mappingPaths(resolve)
    }

    // MARK: - Names and paths

    /// `Main.json`; `Main-2.json` when another configuration already owns the name. A configuration
    /// keeps its file as long as the name it was given for still matches.
    private func fileName(for configuration: JavaRunConfiguration, keeping previous: String?) -> String {
        let base = Self.safeName(configuration.displayName)
        if let previous, Self.stem(of: previous) == base { return previous }
        var candidate = "\(base).json"
        var index = 2
        while let holder = names.first(where: { $0.value == candidate })?.key, holder != configuration.id {
            candidate = "\(base)-\(index).json"
            index += 1
        }
        return candidate
    }

    /// `Main` for `Main.json` and `Main-2.json`.
    private static func stem(of fileName: String) -> String {
        var stem = fileName.hasSuffix(".json") ? String(fileName.dropLast(5)) : fileName
        if let range = stem.range(of: #"-\d+$"#, options: .regularExpression) { stem.removeSubrange(range) }
        return stem
    }

    static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". _"))
        return cleaned.isEmpty ? "configuration" : String(cleaned.prefix(80))
    }

    /// A path inside the project as relative to it; any other path as it is.
    private func relativize(_ path: String) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if path == root.path { return "." }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func resolve(_ path: String) -> String {
        if path.hasPrefix("/") || path.isEmpty { return path }
        if path == "." { return root.path }
        return root.appendingPathComponent(path).standardizedFileURL.path
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
