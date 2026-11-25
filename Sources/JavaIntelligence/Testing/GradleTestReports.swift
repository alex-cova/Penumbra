import Foundation

/// A report is only attributable if exactly one selected task claims its directory and the
/// regular XML file was created or changed within this invocation's observation window.
public struct GradleTestReports: Sendable {
    public struct Row: Codable, Sendable, Identifiable {
        public let id: String
        public let task: String
        public let result: JavaTestCaseResult
    }

    public struct FileVersion: Codable, Equatable, Sendable {
        let modified: Date
        let created: Date?
        let inode: UInt64
        let size: UInt64

        public init?(_ url: URL) {
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  values[.type] as? FileAttributeType == .typeRegular,
                  let modified = values[.modificationDate] as? Date else { return nil }
            self.modified = modified
            created = values[.creationDate] as? Date
            inode = (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            size = (values[.size] as? NSNumber)?.uint64Value ?? 0
        }
    }

    public struct HTMLReport: Codable, Sendable, Identifiable {
        public var id: String { task + "\0" + url.path }
        public let task: String
        public let url: URL
        public let version: FileVersion

        public init?(task: String, url: URL, since: Date) {
            guard let version = FileVersion(url),
                  version.modified >= since || (version.created.map { $0 >= since } ?? false) else { return nil }
            self.task = task
            self.url = url
            self.version = version
        }

        public var isCurrent: Bool { FileVersion(url) == version }
    }

    private let owners: [String: String]
    private let previous: [URL: FileVersion]
    public let started: Date

    public init(directoriesByTask: [String: [URL]], started: Date = Date()) {
        var claims: [String: Set<String>] = [:]
        for (task, directories) in directoriesByTask {
            for directory in directories {
                claims[GradleBuildIdentity.canonicalPath(directory), default: []].insert(task)
            }
        }
        owners = claims.compactMapValues { $0.count == 1 ? $0.first : nil }
        previous = Self.versions(in: owners.keys.map { URL(fileURLWithPath: $0, isDirectory: true) })
        self.started = started
    }

    public func reconcile(excluding tasksWithEvents: Set<String>, didRun tasksWithEvidence: Set<String>) -> [Row] {
        var rows: [Row] = []
        for (file, version) in Self.versions(in: owners.keys.map { URL(fileURLWithPath: $0, isDirectory: true) }).sorted(by: { $0.key.path < $1.key.path }) {
            let directory = file.deletingLastPathComponent()
            guard let task = owners[GradleBuildIdentity.canonicalPath(directory)], !tasksWithEvents.contains(task), tasksWithEvidence.contains(task),
                  previous[file] != version,
                  version.modified >= started || (version.created.map { $0 >= started } ?? false) else { continue }
            let cases = JUnitXMLReportParser.parseVerifiedReport(file)
            guard FileVersion(file) == version else { continue }
            rows += cases.enumerated().map { index, item in
                Row(id: task + "\0" + file.lastPathComponent + "\0" + String(index), task: task, result: item)
            }
        }
        return rows
    }

    private static func versions(in directories: [URL]) -> [URL: FileVersion] {
        var versions: [URL: FileVersion] = [:]
        for directory in directories {
            guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for file in children where file.lastPathComponent.hasPrefix("TEST-") && file.pathExtension == "xml" {
                versions[file] = FileVersion(file)
            }
        }
        return versions
    }
}
