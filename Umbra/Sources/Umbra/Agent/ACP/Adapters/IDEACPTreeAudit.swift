import Foundation

/// Checks a freshly installed npm prefix before it can be activated. Nothing in it is executed.
///
/// Rejected: a symbolic link that leaves the prefix, set-uid / set-gid files, anything writable by
/// everyone, and special files (devices, fifos, sockets). Group and other write bits are removed
/// from what stays, so the permission check at launch passes for a tree Umbra created.
enum IDEACPTreeAudit {
    struct Summary: Equatable, Sendable {
        var files = 0
        var symlinks = 0
        var bytes: Int64 = 0
    }

    @discardableResult
    static func audit(root: URL, normalizePermissions: Bool = true) throws -> Summary {
        let lexicalBase = root.standardizedFileURL.path
        let realBase = IDEACPPaths.real(orSelf: root).path
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true })
        else { throw IDEACPAdapterError.unsafeTree(root.lastPathComponent) }

        var summary = Summary()
        for case let url as URL in walker {
            try Task.checkCancellation()
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw IDEACPAdapterError.unsafeTree(relative) }
            let type = info.st_mode & S_IFMT

            if type == S_IFLNK {
                summary.symlinks += 1
                guard let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
                    throw IDEACPAdapterError.unsafeTree(relative)
                }
                // Where the link really ends up, every link on the way followed. A link whose target
                // does not exist is judged by its spelled-out path.
                let inside: Bool
                if let landing = IDEACPPaths.real(url) {
                    inside = IDEACPPaths.isInside(landing.path, realBase)
                } else {
                    let spelled = target.hasPrefix("/")
                        ? URL(fileURLWithPath: target)
                        : URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
                    inside = IDEACPPaths.isInside(spelled.standardizedFileURL.path, lexicalBase)
                }
                guard inside else {
                    throw IDEACPAdapterError.unsafeTree("\(relative) → \(target)")
                }
                continue
            }
            guard type == S_IFREG || type == S_IFDIR else { throw IDEACPAdapterError.unsafeTree(relative) }
            if info.st_mode & (S_ISUID | S_ISGID) != 0 { throw IDEACPAdapterError.unsafeTree("\(relative) (set-id)") }
            if info.st_mode & 0o002 != 0 { throw IDEACPAdapterError.unsafeTree("\(relative) (world-writable)") }
            if normalizePermissions, info.st_mode & 0o020 != 0 {
                chmod(url.path, info.st_mode & 0o7755)
            }
            if type == S_IFREG {
                summary.files += 1
                summary.bytes += Int64(info.st_blocks) * 512
            }
        }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return summary
    }

    /// The entry script is a regular file inside the package folder. Returns its URL.
    static func entryFile(prefix: URL, package: String, entryPath: String) throws -> URL {
        let packageDirectory = prefix.appendingPathComponent("node_modules/\(package)", isDirectory: true)
        let entry = packageDirectory.appendingPathComponent(entryPath)
        let resolved = IDEACPPaths.real(orSelf: entry)
        let base = IDEACPPaths.real(orSelf: packageDirectory).path
        guard IDEACPPaths.isInside(resolved.path, base), resolved.path != base else {
            throw IDEACPAdapterError.unsafeTree(entryPath)
        }
        var info = stat()
        guard stat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw IDEACPAdapterError.unsafeTree("\(entryPath) (missing entry)")
        }
        return entry
    }
}
