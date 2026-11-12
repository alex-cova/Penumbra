import AgentKit
import Foundation

/// Texts under a workspace before an ACP turn. External agents write files themselves and often
/// emit no `fs/write_text_file` and no diff, so the diff card is filled by comparing this snapshot
/// with the tree after the turn. The walk is capped and skips dependency and build directories.
struct IDEACPWorkspaceSnapshot: Sendable {
    static let maxFileBytes = 256 * 1024
    static let maxFiles = 4_000
    static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", ".swiftpm", "build",
    ]

    var texts: [String: String]
    /// True when the walk stopped at `maxFiles`. Deletions are ignored in that case: a file the
    /// second walk did not reach must not look deleted.
    var hitCap: Bool

    static func capture(root: URL) -> IDEACPWorkspaceSnapshot {
        let root = root.resolvingSymlinksInPath()
        let rootPath = root.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return IDEACPWorkspaceSnapshot(texts: [:], hitCap: false) }

        var texts: [String: String] = [:]
        var hitCap = false
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(item.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if texts.count >= maxFiles {
                hitCap = true
                break
            }
            let resolved = item.resolvingSymlinksInPath()
            let path = resolved.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            guard !relative.isEmpty, let size = values?.fileSize, size <= maxFileBytes else { continue }
            guard let data = try? Data(contentsOf: resolved), data.count <= maxFileBytes,
                  let text = String(data: data, encoding: .utf8) else { continue }
            texts[relative] = text
        }
        return IDEACPWorkspaceSnapshot(texts: texts, hitCap: hitCap)
    }

    static func record(
        before: IDEACPWorkspaceSnapshot, after: IDEACPWorkspaceSnapshot,
        run: RunID, checkpoints: CheckpointLog
    ) async {
        var paths = Set(before.texts.keys)
        paths.formUnion(after.texts.keys)
        for path in paths.sorted() {
            let original = before.texts[path]
            let written = after.texts[path]
            if original == written { continue }
            guard let written else {
                guard !before.hitCap, !after.hitCap, let original else { continue }
                await checkpoints.willChange(run: run, path: path, original: original)
                await checkpoints.didDelete(run: run, path: path)
                continue
            }
            await checkpoints.willChange(run: run, path: path, original: original)
            await checkpoints.didChange(run: run, path: path, written: written)
        }
    }
}
