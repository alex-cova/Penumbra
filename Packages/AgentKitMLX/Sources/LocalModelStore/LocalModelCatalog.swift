import Foundation

/// Written into a model folder as its final act. Its presence is what makes a model "installed".
public struct LocalModelManifest: Codable, Hashable, Sendable {
    public let repositoryID: String
    public let revision: String
    public let downloadedAt: Date
    public let totalBytes: Int64

    public init(repositoryID: String, revision: String, downloadedAt: Date, totalBytes: Int64) {
        self.repositoryID = repositoryID
        self.revision = revision
        self.downloadedAt = downloadedAt
        self.totalBytes = totalBytes
    }
}

public struct InstalledLocalModel: Identifiable, Hashable, Sendable {
    public let manifest: LocalModelManifest
    public let directory: URL

    public init(manifest: LocalModelManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
    }

    public var id: String { manifest.repositoryID }
    public var sizeBytes: Int64 { manifest.totalBytes }
}

/// Scans, reports on and deletes installed models. Never loads weights.
public struct LocalModelCatalog: Sendable {
    public let paths: LocalModelPaths

    public init(paths: LocalModelPaths) {
        self.paths = paths
    }

    public func installed(fileManager: FileManager = .default) -> [InstalledLocalModel] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: paths.root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries
            .compactMap { directory -> InstalledLocalModel? in
                let manifestURL = directory.appendingPathComponent(LocalModelPaths.manifestFileName)
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? decoder.decode(LocalModelManifest.self, from: data),
                      LocalModelPaths.isValidRepositoryID(manifest.repositoryID)
                else { return nil }
                return InstalledLocalModel(manifest: manifest, directory: directory)
            }
            .sorted { $0.manifest.downloadedAt > $1.manifest.downloadedAt }
    }

    public func totalBytes(fileManager: FileManager = .default) -> Int64 {
        installed(fileManager: fileManager).reduce(0) { $0 + $1.sizeBytes }
    }

    public func delete(_ model: InstalledLocalModel, fileManager: FileManager = .default) throws {
        // Only ever remove a folder this catalog itself listed, and only inside the models root.
        let root = paths.root.standardizedFileURL.path
        guard model.directory.standardizedFileURL.path.hasPrefix(root + "/") else {
            throw LocalModelError.unsafeFilePath(model.directory.path)
        }
        try fileManager.removeItem(at: model.directory)
    }

    /// Removes leftovers from downloads that were interrupted by a crash or force-quit.
    /// Paused downloads (checkpoint present) are kept.
    public func clearStaging(fileManager: FileManager = .default) {
        guard let entries = try? fileManager.contentsOfDirectory(at: paths.stagingRoot, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            if LocalModelDownloadCheckpoint.read(from: entry) != nil { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    public func pausedDownload(fileManager: FileManager = .default) -> (checkpoint: LocalModelDownloadCheckpoint, staging: URL)? {
        guard let entries = try? fileManager.contentsOfDirectory(at: paths.stagingRoot, includingPropertiesForKeys: nil) else { return nil }
        for entry in entries {
            if let checkpoint = LocalModelDownloadCheckpoint.read(from: entry) {
                return (checkpoint, entry)
            }
        }
        return nil
    }

    public func discardPausedDownload(staging: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: staging)
    }

    public static func writeManifest(_ manifest: LocalModelManifest, into directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(LocalModelPaths.manifestFileName), options: .atomic)
    }
}
