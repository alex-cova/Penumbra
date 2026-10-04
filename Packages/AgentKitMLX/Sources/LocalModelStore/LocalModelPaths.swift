import Foundation

/// Where models live on disk, and the validation that keeps repository-controlled strings
/// (repo IDs, file paths listed by the Hub) from escaping that folder.
public struct LocalModelPaths: Sendable {
    /// Marker written last inside every installed model. A folder without it is not a model.
    public static let manifestFileName = "hextech-model.json"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/<folderName>/Models` (inside the container when sandboxed).
    public static func defaultRoot(folderName: String? = nil, fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support
            .appendingPathComponent(folderName ?? Bundle.main.bundleIdentifier ?? "LocalModels", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Staging lives under the models root so the final move is a same-volume rename, which is what
    /// makes "installed" all-or-nothing even when the root is on an external drive.
    public var stagingRoot: URL { root.appendingPathComponent(".staging", isDirectory: true) }

    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    public func directory(for repositoryID: String) throws -> URL {
        guard Self.isValidRepositoryID(repositoryID) else { throw LocalModelError.invalidRepositoryID(repositoryID) }
        return root.appendingPathComponent(Self.directoryName(for: repositoryID), isDirectory: true)
    }

    public func newStagingDirectory() -> URL {
        stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - Validation

    /// `owner/name`, each segment starting alphanumeric, so neither can be `.` or `..`.
    public static func isValidRepositoryID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$"#, options: .regularExpression) != nil
    }

    public static func directoryName(for repositoryID: String) -> String {
        repositoryID.replacingOccurrences(of: "/", with: "--")
    }

    /// Resolves a file path from a Hub listing under `base`, refusing anything that could land
    /// outside it. Repository contents are untrusted input.
    public static func safeDestination(for relativePath: String, under base: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw LocalModelError.unsafeFilePath(relativePath) }

        let destination = components.reduce(base) { $0.appendingPathComponent($1) }
        let basePath = base.standardizedFileURL.path
        guard destination.standardizedFileURL.path.hasPrefix(basePath + "/") else {
            throw LocalModelError.unsafeFilePath(relativePath)
        }
        return destination
    }
}

/// Persisted user choice of a non-default models folder. The sandbox only grants access to a
/// user-picked folder through a security-scoped bookmark.
public enum LocalModelStorageBookmark {
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}
