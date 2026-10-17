import Foundation

/// Which paths under a project root Maven reads while building a model: every `pom.xml`, and the
/// files under `.mvn` that change interpolation, the JVM or the wrapper. `target/` and hidden
/// folders are skipped. `.mvn` itself is hidden, so it is visited on its own.
public enum MavenBuildFiles {
    private static let dotMvnFiles: Set<String> = [
        ".mvn/maven.config",
        ".mvn/jvm.config",
        ".mvn/extensions.xml",
        ".mvn/wrapper/maven-wrapper.properties"
    ]

    /// `relativePath` is slash-separated and relative to the project root.
    public static func isBuildInput(relativePath: String) -> Bool {
        let normalized = relativePath.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        if dotMvnFiles.contains(normalized) { return true }
        let components = normalized.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        let directories = components.dropLast()
        for directory in directories {
            if directory.hasPrefix(".") || directory == "target" || GradleBuildFiles.ignoredDirectoryNames.contains(directory) {
                return false
            }
        }
        return name == "pom.xml"
    }

    /// For an absolute path that FSEvents reported under `root`.
    public static func matches(path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return false }
        return isBuildInput(relativePath: String(path.dropFirst(prefix.count)))
    }

    /// Relative paths of every Maven build input under `root`, sorted.
    public static func inputPaths(under root: URL) -> [String] {
        var paths: [String] = []
        for relative in dotMvnFiles.sorted() {
            let file = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: file.path) { paths.append(relative) }
        }
        collect(from: root, relativePrefix: "", into: &paths)
        return paths.sorted()
    }

    private static func collect(from directory: URL, relativePrefix: String, into paths: inout [String]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            let relative = relativePrefix + name
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard name != "target", !GradleBuildFiles.ignoredDirectoryNames.contains(name) else { continue }
                collect(from: entry, relativePrefix: relative + "/", into: &paths)
            } else if name == "pom.xml" {
                paths.append(relative)
            }
        }
    }
}
