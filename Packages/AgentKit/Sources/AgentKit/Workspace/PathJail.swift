import Foundation

/// Keeps every path the model names inside the project. Checked by each file tool before the
/// workspace sees it, because a workspace may only check some of its paths.
public struct PathJail: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The absolute location of a project-relative (or already absolute) path, with symlinks
    /// resolved. A path that doesn't exist yet is checked through its nearest existing ancestor,
    /// so a new file under a symlinked folder can't escape either.
    public func resolve(_ path: String) throws -> URL {
        guard !path.contains("\0") else { throw AgentWorkspaceError.outsideProject(path) }
        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)

        var existing = candidate.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            missing.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component) }
        resolved = resolved.standardizedFileURL

        // The trailing slash keeps `/proj2` from passing for `/proj`.
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw AgentWorkspaceError.outsideProject(path)
        }
        return resolved
    }

    /// Project-relative form of a resolved URL, `""` for the root itself.
    public func relativePath(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == root.path { return "" }
        return String(path.dropFirst(root.path.count + 1))
    }
}
