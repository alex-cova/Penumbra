import Foundation
import JavaIntelligence

/// A breakpoint in a Java source file (1-based line numbers, matching the editor gutter).
struct JavaBreakpoint: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var filePath: String
    var line: Int
    var isEnabled: Bool

    init(id: UUID = UUID(), filePath: String, line: Int, isEnabled: Bool = true) {
        self.id = id
        self.filePath = filePath
        self.line = line
        self.isEnabled = isEnabled
    }
}

/// Persists breakpoints per project root.
final class JavaBreakpointStore: @unchecked Sendable {
    private struct File: Codable {
        var breakpoints: [JavaBreakpoint] = []
    }

    private let storeURL: URL
    private let lock = NSLock()
    private var projects: [String: File]
    private var stamp: FileChangeStamp

    init(storeURL: URL) {
        self.storeURL = storeURL
        projects = Self.load(storeURL) ?? [:]
        stamp = FileChangeStamp(url: storeURL)
    }

    private static func load(_ url: URL) -> [String: File]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: File].self, from: data)
    }

    /// Picks up what another window's store or another process wrote since this one read the file,
    /// so a write here does not drop it. A file that cannot be read keeps what is in memory.
    /// Caller must hold `lock`.
    private func reloadIfChangedOnDisk() {
        guard stamp.hasChanged(at: storeURL) else { return }
        stamp.update(at: storeURL)
        if let loaded = Self.load(storeURL) {
            projects = loaded
        }
    }

    func breakpoints(forProject root: URL?) -> [JavaBreakpoint] {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        return projects[key(for: root)]?.breakpoints ?? []
    }

    func breakpoints(forFile url: URL, project root: URL?) -> [JavaBreakpoint] {
        let path = url.standardizedFileURL.path
        return breakpoints(forProject: root).filter { $0.filePath == path }
    }

    @discardableResult
    func toggle(atLine line: Int, file url: URL, project root: URL?) -> JavaBreakpoint? {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        let path = url.standardizedFileURL.path
        var entry = projects[key(for: root)] ?? File()
        if let index = entry.breakpoints.firstIndex(where: { $0.filePath == path && $0.line == line }) {
            entry.breakpoints.remove(at: index)
            projects[key(for: root)] = entry
            persist()
            return nil
        }
        let breakpoint = JavaBreakpoint(filePath: path, line: line)
        entry.breakpoints.append(breakpoint)
        projects[key(for: root)] = entry
        persist()
        return breakpoint
    }

    func setEnabled(_ enabled: Bool, breakpointID: UUID, project root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        guard var entry = projects[key(for: root)],
              let index = entry.breakpoints.firstIndex(where: { $0.id == breakpointID }) else { return }
        entry.breakpoints[index].isEnabled = enabled
        projects[key(for: root)] = entry
        persist()
    }

    func remove(breakpointID: UUID, project root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        guard var entry = projects[key(for: root)] else { return }
        entry.breakpoints.removeAll { $0.id == breakpointID }
        projects[key(for: root)] = entry
        persist()
    }

    func removeAll(project root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        guard projects[key(for: root)] != nil else { return }
        projects[key(for: root)] = File()
        persist()
    }

    static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("breakpoints.json")
    }

    private func key(for root: URL?) -> String {
        root?.standardizedFileURL.path ?? ""
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
        stamp.update(at: storeURL)
    }
}
