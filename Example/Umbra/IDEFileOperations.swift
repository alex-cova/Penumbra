import Foundation

/// File-system operations behind the Explorer's context menu. UI-free: `IDEWorkspace` wraps these
/// with confirmation, open-tab retargeting, and tree refresh. Every target must stay inside the
/// project root.
struct IDEFileOperations {
    enum Failure: LocalizedError {
        case invalidName(String)
        case nameExists(String)
        case outsideProject
        case isProjectRoot

        var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                return "“\(name)” is not a valid file name."
            case .nameExists(let name):
                return "An item named “\(name)” already exists in this folder."
            case .outsideProject:
                return "That location is outside the project folder."
            case .isProjectRoot:
                return "The project folder itself can't be changed from the Explorer."
            }
        }
    }

    let rootURL: URL

    /// Trims and rejects empty names, path separators, and `.`/`..`.
    func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains(":") else {
            throw Failure.invalidName(name)
        }
        return trimmed
    }

    @discardableResult
    func createFile(in directory: URL, name: String) throws -> URL {
        let destination = try target(in: directory, name: name)
        guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        return destination
    }

    @discardableResult
    func createDirectory(in directory: URL, name: String) throws -> URL {
        let destination = try target(in: directory, name: name)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    /// A name for a new item in `directory` that doesn't collide: `base`, `base 2`, `base 3`, …
    func uniqueName(base: String, extension ext: String = "", in directory: URL) -> String {
        func make(_ index: Int?) -> String {
            let stem = index.map { "\(base) \($0)" } ?? base
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var index: Int?
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(make(index)).path) {
            index = (index ?? 1) + 1
        }
        return make(index)
    }

    @discardableResult
    func rename(_ url: URL, to name: String) throws -> URL {
        try requireInsideProject(url)
        let destination = try target(in: url.deletingLastPathComponent(), name: name, replacing: url)
        guard destination != url else { return url }
        if destination.path.lowercased() == url.path.lowercased() {
            // Case-only rename on a case-insensitive volume: hop through a temporary name.
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".umbra-rename-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: temporary)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } else {
            try FileManager.default.moveItem(at: url, to: destination)
        }
        return destination
    }

    /// Moves a file into another folder (creating intermediate directories). The destination URL's
    /// last path component is the new file name.
    @discardableResult
    func move(_ url: URL, to destinationURL: URL) throws -> URL {
        try requireInsideProject(url)
        let directory = destinationURL.deletingLastPathComponent()
        try requireInsideProject(directory, allowingRoot: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw Failure.nameExists(destinationURL.lastPathComponent)
        }
        try FileManager.default.moveItem(at: url, to: destinationURL)
        return destinationURL
    }

    /// Copies next to the original as `name copy.ext`, `name copy 2.ext`, …
    @discardableResult
    func duplicate(_ url: URL) throws -> URL {
        try requireInsideProject(url)
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let destination = directory.appendingPathComponent(uniqueName(base: "\(stem) copy", extension: ext, in: directory))
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    func trash(_ url: URL) throws {
        try requireInsideProject(url)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func relativePath(of url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    // MARK: - Private

    private func target(in directory: URL, name: String, replacing existing: URL? = nil) throws -> URL {
        let valid = try validated(name)
        try requireInsideProject(directory, allowingRoot: true)
        let destination = directory.appendingPathComponent(valid)
        if FileManager.default.fileExists(atPath: destination.path) {
            // A case-only rename of the item itself "exists" on a case-insensitive volume.
            let isSelf = existing.map { $0.path.lowercased() == destination.path.lowercased() } ?? false
            if !isSelf { throw Failure.nameExists(valid) }
        }
        return destination
    }

    private func requireInsideProject(_ url: URL, allowingRoot: Bool = false) throws {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root {
            if allowingRoot { return }
            throw Failure.isProjectRoot
        }
        guard path.hasPrefix(root + "/") else { throw Failure.outsideProject }
    }
}
