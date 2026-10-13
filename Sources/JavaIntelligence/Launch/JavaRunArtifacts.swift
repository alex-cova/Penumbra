import CryptoKit
import Foundation

/// Where the files of coverage and profiling runs go, and how they are kept in check.
///
/// `<root>/<Coverage|Profiles>/<project hash>/<run id>/`, under the app's cache directory: it is
/// disposable data, never in the project folder, pruned to the newest few runs and a size cap.
public struct JavaRunArtifacts: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case coverage = "Coverage"
        case profile = "Profiles"

        /// How many runs of this kind are kept per project.
        public var defaultKeepCount: Int {
            switch self {
            case .coverage: return 5
            case .profile: return 10
            }
        }
    }

    /// One run's directory.
    public struct Run: Equatable, Sendable {
        public var kind: Kind
        public var id: String
        public var directory: URL
        public var modified: Date
        public var bytes: Int
    }

    /// The most that all runs of a kind may hold together, per project.
    public static let defaultMaximumBytes = 500 * 1024 * 1024

    public let root: URL

    /// - Parameter root: `Caches/com.umbra.editor`, or a temporary directory in tests.
    public init(root: URL) {
        self.root = root
    }

    /// A short stable name for a project folder, so two projects never share a directory.
    public static func projectHash(for projectRoot: URL) -> String {
        let digest = SHA256.hash(data: Data(projectRoot.standardizedFileURL.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func projectDirectory(kind: Kind, projectHash: String) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true).appendingPathComponent(projectHash, isDirectory: true)
    }

    /// Creates and returns a new run directory. The id sorts by time, so listing by name and by
    /// date agree.
    public func allocate(kind: Kind, projectHash: String, now: Date = Date(), suffix: String = UUID().uuidString.prefix(6).lowercased()) throws -> Run {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = formatter.string(from: now) + "-" + suffix
        let directory = projectDirectory(kind: kind, projectHash: projectHash).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Run(kind: kind, id: id, directory: directory, modified: now, bytes: 0)
    }

    /// The project's runs of `kind`, newest first.
    public func runs(kind: Kind, projectHash: String) -> [Run] {
        let parent = projectDirectory(kind: kind, projectHash: projectHash)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [Run] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            result.append(Run(
                kind: kind, id: entry.lastPathComponent, directory: entry,
                modified: values?.contentModificationDate ?? .distantPast, bytes: Self.size(of: entry)
            ))
        }
        return result.sorted { lhs, rhs in
            lhs.modified != rhs.modified ? lhs.modified > rhs.modified : lhs.id > rhs.id
        }
    }

    /// Removes the oldest runs past `keep`, then the oldest until the rest fit in `maximumBytes`.
    /// `protecting` names runs that must stay (the one on screen). Returns what was removed.
    @discardableResult
    public func prune(
        kind: Kind,
        projectHash: String,
        keep: Int? = nil,
        maximumBytes: Int = JavaRunArtifacts.defaultMaximumBytes,
        protecting: Set<String> = []
    ) -> [Run] {
        let keepCount = max(1, keep ?? kind.defaultKeepCount)
        var kept = runs(kind: kind, projectHash: projectHash)
        var removed: [Run] = []
        func remove(_ run: Run) {
            try? FileManager.default.removeItem(at: run.directory)
            removed.append(run)
            kept.removeAll { $0.id == run.id }
        }
        // Newest first: what is past the count goes, oldest last in the list.
        for run in kept.dropFirst(keepCount).reversed() where !protecting.contains(run.id) {
            remove(run)
        }
        var total = kept.reduce(0) { $0 + $1.bytes }
        for run in kept.reversed() where total > maximumBytes && kept.count > 1 && !protecting.contains(run.id) {
            total -= run.bytes
            remove(run)
        }
        return removed
    }

    /// Prunes every project and kind under the root: the once-a-day sweep when a project opens.
    public func pruneAll(maximumBytes: Int = JavaRunArtifacts.defaultMaximumBytes) {
        for kind in Kind.allCases {
            let parent = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard let projects = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { continue }
            for project in projects {
                prune(kind: kind, projectHash: project.lastPathComponent, maximumBytes: maximumBytes)
            }
        }
    }

    public func delete(_ run: Run) {
        try? FileManager.default.removeItem(at: run.directory)
    }

    private static func size(of directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey], options: []
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
        }
        return total
    }
}
