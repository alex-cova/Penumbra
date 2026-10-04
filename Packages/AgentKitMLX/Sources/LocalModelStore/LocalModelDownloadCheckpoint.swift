import Foundation

/// Persisted in a staging folder so a paused download survives navigation and relaunch.
public struct LocalModelDownloadCheckpoint: Codable, Hashable, Sendable {
    public static let fileName = "hextech-download.json"

    public let repositoryID: String
    public let revision: String
    public let totalBytes: Int64
    public let completedBytes: Int64
    public let completedFiles: [String]
    public let currentFile: String?
    public let resumeData: Data?
    public let pausedAt: Date

    public init(
        repositoryID: String, revision: String, totalBytes: Int64, completedBytes: Int64, completedFiles: [String],
        currentFile: String?, resumeData: Data?, pausedAt: Date
    ) {
        self.repositoryID = repositoryID
        self.revision = revision
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.completedFiles = completedFiles
        self.currentFile = currentFile
        self.resumeData = resumeData
        self.pausedAt = pausedAt
    }

    public var progress: LocalModelDownloadProgress {
        LocalModelDownloadProgress(
            bytesDownloaded: completedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: nil,
            currentFile: currentFile,
            isPaused: true
        )
    }

    public func write(into staging: URL, fileManager: FileManager = .default) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: staging.appendingPathComponent(Self.fileName),
            options: .atomic
        )
    }

    public static func read(from staging: URL, fileManager: FileManager = .default) -> LocalModelDownloadCheckpoint? {
        let url = staging.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LocalModelDownloadCheckpoint.self, from: data)
    }
}
