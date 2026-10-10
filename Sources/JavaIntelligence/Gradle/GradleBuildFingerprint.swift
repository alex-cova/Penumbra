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
    /// Walks `projectRoot` and collects stamps for every path ``GradleBuildFiles`` treats as a build
    /// input (root scripts, version catalogs, wrapper properties, and subproject scripts).
    public static func collect(projectRoot: URL) -> GradleBuildFingerprint {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let stamps: [GradleBuildFingerprint.FileStamp] = GradleBuildFiles.inputPaths(under: root).compactMap { relative in
            guard let stamp = JavaStamp(url: root.appendingPathComponent(relative)) else { return nil }
            return .init(relativePath: relative, size: stamp.size, modificationDate: stamp.modificationDate)
        }
        return GradleBuildFingerprint(
            scriptFormatVersion: GradleProjectModelScript.formatVersion,
            files: stamps
        )
    }
}
