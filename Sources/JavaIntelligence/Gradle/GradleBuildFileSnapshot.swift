import Foundation

/// The bytes of every Gradle build input under a project root at one moment.
///
/// A file system event only says a build file was *touched*: a save of an unchanged tab, `touch`,
/// `chmod` and extended-attribute writes all produce one. Comparing against a snapshot answers the
/// question the reload banner is really asking: does what Gradle would read now differ from what it
/// read last time. Build scripts are small, so keeping their bytes is cheaper than a hash plus a
/// second read.
public struct GradleBuildFileSnapshot: Sendable, Equatable {
    /// Relative path to content.
    public let contents: [String: Data]

    public init(contents: [String: Data]) {
        self.contents = contents
    }

    /// Reads every build input under `projectRoot`. Synchronous file I/O: call it off the main actor.
    public static func capture(projectRoot: URL) -> GradleBuildFileSnapshot {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        var contents: [String: Data] = [:]
        for relative in GradleBuildFiles.inputPaths(under: root) {
            if let data = try? Data(contentsOf: root.appendingPathComponent(relative)) {
                contents[relative] = data
            }
        }
        return GradleBuildFileSnapshot(contents: contents)
    }

    /// Whether the file at `relativePath` under `projectRoot` is now different from the snapshot:
    /// edited, added since, or deleted since. A file the snapshot never had and that is not on disk
    /// either is not a difference.
    public func differs(relativePath: String, projectRoot: URL) -> Bool {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let current = try? Data(contentsOf: root.appendingPathComponent(relativePath))
        return current != contents[relativePath]
    }
}
