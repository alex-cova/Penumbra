import Foundation

/// Where a dependency jar came from, read off its path. Gradle's cache keeps
/// `modules-2/files-2.1/<group>/<artifact>/<version>/<hash>/<file>.jar`; a Maven repository keeps
/// `<group as folders>/<artifact>/<version>/<artifact>-<version>[-<classifier>].jar`. Any other jar is
/// `.local` and is labeled by its file name.
public struct JavaLibraryCoordinates: Equatable, Sendable {
    public enum Origin: Sendable {
        case gradle, maven, local
    }

    public let origin: Origin
    public let group: String
    public let artifact: String
    public let version: String
    public let classifier: String?

    /// The Explorer's name for the library: `Gradle: org.slf4j:slf4j-api:2.0.9`, `Maven: …` or the
    /// jar's file name.
    public let label: String

    public static func parse(jar: URL) -> JavaLibraryCoordinates {
        let components = jar.standardizedFileURL.pathComponents
        let fileName = jar.lastPathComponent
        if let gradle = parseGradle(components) { return gradle }
        if let maven = parseMaven(components) { return maven }
        return JavaLibraryCoordinates(
            origin: .local, group: "", artifact: fileName, version: "", classifier: nil, label: fileName
        )
    }

    private static func parseGradle(_ components: [String]) -> JavaLibraryCoordinates? {
        guard let marker = components.lastIndex(of: "files-2.1"),
              marker > 0, components[marker - 1] == "modules-2" else { return nil }
        // group, artifact, version, hash, file
        let rest = components[(marker + 1)...]
        guard rest.count == 5 else { return nil }
        let parts = Array(rest)
        let group = parts[0], artifact = parts[1], version = parts[2]
        return JavaLibraryCoordinates(
            origin: .gradle, group: group, artifact: artifact, version: version,
            classifier: classifier(fileName: parts[4], artifact: artifact, version: version),
            label: "Gradle: \(group):\(artifact):\(version)"
        )
    }

    private static func parseMaven(_ components: [String]) -> JavaLibraryCoordinates? {
        guard components.count >= 5 else { return nil }
        let fileName = components[components.count - 1]
        let version = components[components.count - 2]
        let artifact = components[components.count - 3]
        let prefix = artifact + "-" + version
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".jar") else { return nil }
        // The group is every folder between the repository root and the artifact.
        guard let root = components.lastIndex(of: "repository"), root < components.count - 4 else { return nil }
        let group = components[(root + 1)..<(components.count - 3)].joined(separator: ".")
        return JavaLibraryCoordinates(
            origin: .maven, group: group, artifact: artifact, version: version,
            classifier: classifier(fileName: fileName, artifact: artifact, version: version),
            label: "Maven: \(group):\(artifact):\(version)"
        )
    }

    private static func classifier(fileName: String, artifact: String, version: String) -> String? {
        let prefix = artifact + "-" + version + "-"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".jar") else { return nil }
        let value = fileName.dropFirst(prefix.count).dropLast(".jar".count)
        return value.isEmpty ? nil : String(value)
    }
}
