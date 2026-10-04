import AgentKit
import Foundation

/// A throwaway copy of a task's project, so every trial starts from the same files.
public struct Sandbox: Sendable {
    public let root: URL

    public static func create(from project: URL) throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-eval-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.copyItem(at: project, to: root)
        return Sandbox(root: root)
    }

    public func remove() { try? FileManager.default.removeItem(at: root) }

    /// Lays `overlay` over the sandbox (the reference solution).
    public func overlay(_ overlay: URL) throws {
        for path in Self.files(under: overlay).keys {
            let destination = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: overlay.appendingPathComponent(path), to: destination)
        }
    }

    /// Relative path to a content hash, for every file. Interpreter caches are left out: running the
    /// tests creates them and they are not the agent's work.
    public func snapshot() -> [String: UInt64] { Self.files(under: root) }

    static func files(under base: URL) -> [String: UInt64] {
        let base = base.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: UInt64] = [:]
        for case let url as URL in walker {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1))
            if relative.split(separator: "/").contains("__pycache__") || relative.hasSuffix(".pyc") { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url)
            else { continue }
            result[relative] = fnv(data)
        }
        return result
    }

    static func fnv(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hash
    }

    /// Protected files that were changed, created or removed between two snapshots.
    public static func violations(protected globs: [String], before: [String: UInt64], after: [String: UInt64]) -> [String] {
        let patterns = globs.compactMap { try? GlobPattern($0) }
        let paths = Set(before.keys).union(after.keys).filter { path in patterns.contains { $0.matches(path) } }
        return paths.filter { before[$0] != after[$0] }.sorted()
    }

    /// Everything the agent added, changed or removed.
    public static func changes(before: [String: UInt64], after: [String: UInt64]) -> [String] {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }
}
