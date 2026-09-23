import Foundation

/// A snapshot of every Gradle build-input file's path, size, and modification date under a project
/// root. Used to decide whether a cached ``JavaGradleProjectModel`` is still valid without running
/// Gradle.
public struct GradleBuildFingerprint: Codable, Hashable, Sendable {
    public struct FileStamp: Codable, Hashable, Sendable {
        public let relativePath: String
        public let size: Int64
        public let modificationDate: TimeInterval

        public init(relativePath: String, size: Int64, modificationDate: TimeInterval) {
            self.relativePath = relativePath
            self.size = size
            self.modificationDate = modificationDate
        }
    }

    public let scriptFormatVersion: Int
    public let files: [FileStamp]

    public init(scriptFormatVersion: Int, files: [FileStamp]) {
        self.scriptFormatVersion = scriptFormatVersion
        self.files = files.sorted { $0.relativePath < $1.relativePath }
    }
}

public enum GradleBuildFingerprintCollector {
    private static let ignoredDirectoryNames: Set<String> = [
        ".git", ".gradle", "build", "out", "node_modules", ".idea", ".vscode"
    ]

    /// Walks `projectRoot` and collects stamps for every path ``GradleBuildFiles`` would treat as a
    /// build input (root scripts, version catalogs, wrapper properties, and subproject scripts).
    public static func collect(projectRoot: URL) -> GradleBuildFingerprint {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        var stamps: [GradleBuildFingerprint.FileStamp] = []
        collect(from: root, projectRootPath: root.path, into: &stamps)
        return GradleBuildFingerprint(
            scriptFormatVersion: GradleProjectModelScript.formatVersion,
            files: stamps
        )
    }

    private static func collect(from directory: URL, projectRootPath: String, into stamps: inout [GradleBuildFingerprint.FileStamp]) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                guard !ignoredDirectoryNames.contains(entry.lastPathComponent) else { continue }
                collect(from: entry, projectRootPath: projectRootPath, into: &stamps)
                continue
            }

            let path = entry.standardizedFileURL.resolvingSymlinksInPath().path
            guard GradleBuildFiles.matches(path: path) else { continue }
            guard let stamp = JavaStamp(url: entry) else { continue }
            let relative = path.hasPrefix(projectRootPath + "/")
                ? String(path.dropFirst(projectRootPath.count + 1))
                : entry.lastPathComponent
            stamps.append(.init(
                relativePath: relative,
                size: stamp.size,
                modificationDate: stamp.modificationDate
            ))
        }
    }
}
