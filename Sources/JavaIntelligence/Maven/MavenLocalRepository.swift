import Foundation

/// Where Maven keeps downloaded artifacts, and the path of one artifact inside it.
///
/// The repository is chosen in Maven's order: `-Dmaven.repo.local` in `.mvn/maven.config`, then
/// `<localRepository>` in `~/.m2/settings.xml` or `$MAVEN_HOME/conf/settings.xml`, then
/// `~/.m2/repository`.
public enum MavenLocalRepository {
    public static func resolve(
        projectRoot: URL,
        mavenConfig: MavenConfigFile? = nil,
        userHome: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        let mavenConfig = mavenConfig ?? MavenConfigFile.read(projectRoot: projectRoot)
        if let override = mavenConfig.properties["maven.repo.local"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let home = userHome ?? fileManager.homeDirectoryForCurrentUser
        if let declared = localRepository(in: home.appendingPathComponent(".m2/settings.xml")) {
            return declared
        }
        if let mavenHome = environment["MAVEN_HOME"], !mavenHome.isEmpty,
           let declared = localRepository(in: URL(fileURLWithPath: mavenHome).appendingPathComponent("conf/settings.xml")) {
            return declared
        }
        return home.appendingPathComponent(".m2/repository", isDirectory: true)
    }

    /// `group/artifact/version/artifact-version[-classifier].ext`. A SNAPSHOT uses the base-version
    /// file when it is there, otherwise the newest timestamped file.
    public static func artifactURL(
        groupId: String,
        artifactId: String,
        version: String,
        classifier: String = "",
        extension ext: String = "jar",
        repository: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let folder = artifactDirectory(
            groupId: groupId, artifactId: artifactId, version: version, repository: repository
        )
        let baseName = fileName(artifactId: artifactId, version: version, classifier: classifier, extension: ext)
        let base = folder.appendingPathComponent(baseName)
        if fileManager.fileExists(atPath: base.path) { return base }
        guard version.contains("SNAPSHOT") else { return nil }
        return newestSnapshot(
            in: folder, artifactId: artifactId, version: version, classifier: classifier, extension: ext, fileManager: fileManager
        )
    }

    public static func artifactDirectory(groupId: String, artifactId: String, version: String, repository: URL) -> URL {
        var url = repository
        for part in groupId.split(separator: ".") {
            url = url.appendingPathComponent(String(part), isDirectory: true)
        }
        return url
            .appendingPathComponent(artifactId, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    /// Version directories under `group/artifact`, for a version range.
    public static func installedVersions(
        groupId: String, artifactId: String, repository: URL, fileManager: FileManager = .default
    ) -> [String] {
        var url = repository
        for part in groupId.split(separator: ".") {
            url = url.appendingPathComponent(String(part), isDirectory: true)
        }
        url = url.appendingPathComponent(artifactId, isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.filter { name in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue && !name.hasPrefix(".")
        }
    }

    public static func fileName(artifactId: String, version: String, classifier: String, extension ext: String) -> String {
        var name = "\(artifactId)-\(version)"
        if !classifier.isEmpty { name += "-\(classifier)" }
        return name + ".\(ext)"
    }

    private static func newestSnapshot(
        in folder: URL,
        artifactId: String,
        version: String,
        classifier: String,
        extension ext: String,
        fileManager: FileManager
    ) -> URL? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return nil }
        let base = version.replacingOccurrences(of: "-SNAPSHOT", with: "")
        let prefix = "\(artifactId)-\(base)-"
        let suffix = (classifier.isEmpty ? "" : "-\(classifier)") + ".\(ext)"
        let matches = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.sorted()
        guard let newest = matches.last else { return nil }
        return folder.appendingPathComponent(newest)
    }

    private static func localRepository(in settings: URL) -> URL? {
        guard let data = try? Data(contentsOf: settings),
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard let start = text.range(of: "<localRepository>"), let end = text.range(of: "</localRepository>") else {
            return nil
        }
        let value = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
    }
}

/// `.mvn/maven.config`: `-Dname=value` properties and `-P` profiles. Lines may hold several arguments.
public struct MavenConfigFile: Sendable, Equatable {
    public var properties: [String: String]
    public var profiles: [String]
    /// Profiles switched off with `-P!name`.
    public var disabledProfiles: [String]

    public init(properties: [String: String] = [:], profiles: [String] = [], disabledProfiles: [String] = []) {
        self.properties = properties
        self.profiles = profiles
        self.disabledProfiles = disabledProfiles
    }

    public static func read(projectRoot: URL, fileManager: FileManager = .default) -> MavenConfigFile {
        let file = projectRoot.appendingPathComponent(".mvn/maven.config")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return MavenConfigFile() }
        return parse(text)
    }

    public static func parse(_ text: String) -> MavenConfigFile {
        var properties: [String: String] = [:]
        var profiles: [String] = []
        var disabled: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            for token in splitArguments(line) {
                if token.hasPrefix("-D") {
                    let body = String(token.dropFirst(2))
                    let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    let name = parts.first ?? ""
                    guard !name.isEmpty else { continue }
                    properties[name] = parts.count > 1 ? parts[1] : "true"
                } else if token.hasPrefix("-P") {
                    for id in token.dropFirst(2).split(separator: ",") {
                        let name = String(id)
                        if name.hasPrefix("!") {
                            let stripped = String(name.dropFirst())
                            if !stripped.isEmpty { disabled.append(stripped) }
                        } else if !name.isEmpty {
                            profiles.append(name)
                        }
                    }
                }
            }
        }
        return MavenConfigFile(properties: properties, profiles: profiles, disabledProfiles: disabled)
    }

    /// Splits on spaces, keeping a quoted argument together.
    static func splitArguments(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " || character == "\t" {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
