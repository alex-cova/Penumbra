import Foundation

/// Which JDK each project uses, a default for every project, and the JDKs the user added by hand,
/// kept in a small JSON file so they survive a restart. Projects are keyed by the root's path.
///
/// Like ``GradleTrustStore`` it should live in a stable, non-cache location (Umbra uses
/// `~/Library/Application Support/<bundle id>/jdk-selection.json`).
public final class JDKSelectionStore: @unchecked Sendable {
    private struct File: Codable {
        var version = 1
        var global: String?
        var projects: [String: String] = [:]
        var customJDKs: [String] = []
    }

    private let storeURL: URL
    private let lock = NSLock()
    private var file: File
    private var stamp: FileChangeStamp

    public init(storeURL: URL) {
        self.storeURL = storeURL
        file = Self.load(storeURL) ?? File()
        stamp = FileChangeStamp(url: storeURL)
    }

    private static func load(_ url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    /// Picks up a choice another window's store or another process wrote since this one read the
    /// file, so a write here does not drop it. A file that cannot be read keeps what is in memory.
    /// Caller must hold `lock`.
    private func reloadIfChangedOnDisk() {
        guard stamp.hasChanged(at: storeURL) else { return }
        stamp.update(at: storeURL)
        if let loaded = Self.load(storeURL) {
            file = loaded
        }
    }

    /// The project's JDK and the default, as chosen. Paths are not checked here.
    public func selection(forProject root: URL?) -> JDKSelection {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        return JDKSelection(
            project: root.flatMap { file.projects[key(for: $0)] }.map { URL(fileURLWithPath: $0) },
            global: file.global.map { URL(fileURLWithPath: $0) }
        )
    }

    /// `nil` puts the project back on Automatic (or the default).
    public func setProject(_ home: URL?, forProject root: URL) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        file.projects[key(for: root)] = home.map(path(of:))
        persist()
    }

    /// `nil` puts every project without its own choice back on Automatic.
    public func setGlobal(_ home: URL?) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        file.global = home.map(path(of:))
        persist()
    }

    /// JDK homes the user added, in the order they were added.
    public var customJDKs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        return file.customJDKs.map { URL(fileURLWithPath: $0) }
    }

    /// Adds `home` unless a JDK at the same resolved path is already there. Returns `false` for a
    /// duplicate.
    @discardableResult
    public func addCustomJDK(_ home: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        let added = path(of: home)
        guard !file.customJDKs.contains(where: { resolved($0) == added }) else { return false }
        file.customJDKs.append(added)
        persist()
        return true
    }

    /// Removes the added JDK at `home`. A project or default that chose it keeps the path, which
    /// then resolves as a stale selection.
    public func removeCustomJDK(_ home: URL) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        let target = path(of: home)
        file.customJDKs.removeAll { resolved($0) == target }
        persist()
    }

    /// The roots whose own JDK is `home`, plus whether it is the default. Used to warn before a
    /// removal.
    public func usage(of home: URL) -> (projects: [String], isDefault: Bool) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        let target = path(of: home)
        let projects = file.projects.filter { resolved($0.value) == target }.map(\.key).sorted()
        return (projects, file.global.map { resolved($0) == target } ?? false)
    }

    private func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func path(of home: URL) -> String {
        home.resolvingSymlinksInPath().path
    }

    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Caller must hold `lock`.
    private func persist() {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
        stamp.update(at: storeURL)
    }
}
