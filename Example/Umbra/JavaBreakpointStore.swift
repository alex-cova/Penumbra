import Foundation

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

    init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([String: File].self, from: data) {
            projects = decoded
        } else {
            projects = [:]
        }
    }

    func breakpoints(forProject root: URL?) -> [JavaBreakpoint] {
        lock.lock()
        defer { lock.unlock() }
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
        guard var entry = projects[key(for: root)],
              let index = entry.breakpoints.firstIndex(where: { $0.id == breakpointID }) else { return }
        entry.breakpoints[index].isEnabled = enabled
        projects[key(for: root)] = entry
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
    }
}
