import Foundation

/// How to launch a Java program: what to run, and the arguments and environment to run it with.
public struct JavaRunConfiguration: Codable, Equatable, Sendable {
    public enum Target: Codable, Equatable, Sendable {
        /// The Gradle `run` task of a project: `":"` for the root project, else `":app"` and so on.
        case gradleRun(projectPath: String)
        /// A single `.java` file launched with `java File.java`.
        case singleFile(path: String)
    }

    public var target: Target
    /// Arguments for the program. For Gradle they go to `--args`; for a single file they follow
    /// the file name, and are typed into the shell as written, so quoting works as usual.
    public var programArguments: String
    /// Options for the JVM (`-Xmx512m -Dkey=value`). Single-file launches only: Gradle's `run`
    /// task takes them from the build script, not the command line.
    public var vmArguments: String
    public var environment: [String: String]

    public init(
        target: Target,
        programArguments: String = "",
        vmArguments: String = "",
        environment: [String: String] = [:]
    ) {
        self.target = target
        self.programArguments = programArguments
        self.vmArguments = vmArguments
        self.environment = environment
    }

    /// A short name for menus: `Gradle run (:app)` or the file's name.
    public var displayName: String {
        switch target {
        case .gradleRun(let projectPath):
            return projectPath == ":" ? "Gradle run" : "Gradle run (\(projectPath))"
        case .singleFile(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    /// Whether ``vmArguments`` can be passed to this target.
    public var supportsVMArguments: Bool {
        if case .singleFile = target { return true }
        return false
    }

    /// `NAME=value` lines, one variable each, for an editable text field. Blank lines and lines
    /// starting with `#` are ignored; a line without `=` is dropped, and the first `=` splits the
    /// name from a value that may itself contain `=`.
    public static func parseEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result[name] = String(trimmed[trimmed.index(after: equals)...])
        }
        return result
    }

    /// The inverse of ``parseEnvironment(_:)``: `NAME=value` lines, sorted by name.
    public static func environmentText(_ environment: [String: String]) -> String {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    /// The configuration Run uses for `file` before the user edits anything: the Gradle `run`
    /// task of the file's subproject in a Gradle project, else a single-file launch.
    public static func makeDefault(
        file: URL?,
        projectRoot: URL?,
        isGradleProject: Bool,
        model: JavaGradleProjectModel?
    ) -> JavaRunConfiguration? {
        if isGradleProject, projectRoot != nil {
            let path = file.flatMap { model?.sourceSet(containing: $0)?.subproject.path } ?? ":"
            return JavaRunConfiguration(target: .gradleRun(projectPath: path))
        }
        guard let file, file.pathExtension.lowercased() == "java" else { return nil }
        return JavaRunConfiguration(target: .singleFile(path: file.path))
    }

    /// This configuration's target with the arguments and environment of `previous`, when
    /// `previous` ran the same target: so running a file again keeps what was typed for it.
    public func inheritingSettings(from previous: JavaRunConfiguration?) -> JavaRunConfiguration {
        guard let previous, previous.target == target else { return self }
        var result = self
        result.programArguments = previous.programArguments
        result.vmArguments = previous.vmArguments
        result.environment = previous.environment
        return result
    }
}

/// The last run configuration of each project, kept in a small JSON file so Run Last
/// Configuration survives a restart. Keyed by the project root's path (`""` for no project).
///
/// Like ``GradleTrustStore`` it should live in a stable, non-cache location (Umbra uses
/// `~/Library/Application Support/<bundle id>/run-configurations.json`).
public final class JavaRunConfigurationStore: @unchecked Sendable {
    private let storeURL: URL
    private let lock = NSLock()
    private var configurations: [String: JavaRunConfiguration]

    public init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([String: JavaRunConfiguration].self, from: data) {
            configurations = decoded
        } else {
            configurations = [:]
        }
    }

    public func last(forProject root: URL?) -> JavaRunConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return configurations[key(for: root)]
    }

    public func setLast(_ configuration: JavaRunConfiguration, forProject root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        configurations[key(for: root)] = configuration
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private func key(for root: URL?) -> String {
        root?.standardizedFileURL.path ?? ""
    }
}
