import Foundation

/// The JaCoCo agent and CLI jars Umbra ships next to the debug adapter.
///
/// They are fetched by `Example/Umbra/Tools/JaCoCo/fetch.sh` (pinned, SHA-256 checked) and are
/// not in the repository, so a build can lack them; ``locate(in:fileExists:)`` says so in a
/// sentence instead of failing in the middle of a run.
public struct JavaCoverageToolchain: Equatable, Sendable {
    /// `jacocoagent.jar`, passed as `-javaagent:`.
    public let agentJar: URL
    /// `jacococli.jar`, run with `java -jar` to turn `.exec` files into a report.
    public let cliJar: URL

    public init(agentJar: URL, cliJar: URL) {
        self.agentJar = agentJar
        self.cliJar = cliJar
    }

    /// The JaCoCo release the jars are pinned to; `fetch.sh` carries the same number.
    public static let version = "0.8.15"

    /// The newest class file major version (Java 26 is 70) the pinned release officially supports.
    /// A project compiled for a newer Java fails in the CLI with a stack trace, so
    /// ``unsupportedLanguageLevel(_:)`` turns that into one sentence before the run.
    public static let supportedClassFileMajor = 70

    /// Java feature version of a class file major (`52` is Java 8, `61` is 17).
    public static func featureVersion(ofClassFileMajor major: Int) -> Int { major - 44 }

    public static var supportedFeatureVersion: Int { featureVersion(ofClassFileMajor: supportedClassFileMajor) }

    public enum LocateError: Error, Equatable, LocalizedError, Sendable {
        case notBundled(missing: [String])

        public var errorDescription: String? {
            switch self {
            case .notBundled(let missing):
                return "Coverage needs \(missing.joined(separator: " and ")), which this build of Umbra does not include. "
                    + "Run Example/Umbra/Tools/JaCoCo/fetch.sh and rebuild."
            }
        }
    }

    /// The jars in the first of `directories` that holds both.
    public static func locate(
        in directories: [URL],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> JavaCoverageToolchain {
        for directory in directories {
            let agent = directory.appendingPathComponent("jacocoagent.jar")
            let cli = directory.appendingPathComponent("jacococli.jar")
            if fileExists(agent.path), fileExists(cli.path) {
                return JavaCoverageToolchain(agentJar: agent, cliJar: cli)
            }
        }
        // Name what is missing in the most promising directory (the first), for the message.
        var missing: [String] = []
        if let first = directories.first {
            for name in ["jacocoagent.jar", "jacococli.jar"] where !fileExists(first.appendingPathComponent(name).path) {
                missing.append(name)
            }
        }
        throw LocateError.notBundled(missing: missing.isEmpty ? ["jacocoagent.jar", "jacococli.jar"] : missing)
    }

    /// A sentence when `featureVersion` is newer than the pinned JaCoCo supports; `nil` otherwise.
    public static func unsupportedLanguageLevel(_ featureVersion: Int?) -> String? {
        guard let featureVersion, featureVersion > supportedFeatureVersion else { return nil }
        return "The coverage tool (JaCoCo \(version)) supports up to Java \(supportedFeatureVersion), "
            + "and this project builds for Java \(featureVersion). Run without coverage, or choose an older Java."
    }
}
