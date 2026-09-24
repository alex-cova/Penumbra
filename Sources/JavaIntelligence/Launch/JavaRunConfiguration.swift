import Foundation

/// How to launch a Java program: what to run, and the arguments and environment to run it with.
public struct JavaRunConfiguration: Codable, Equatable, Sendable {
    public enum Target: Codable, Equatable, Sendable {
        /// The Gradle `run` task of a project: `":"` for the root project, else `":app"` and so on.
        case gradleRun(projectPath: String)
        /// A single `.java` file launched with `java File.java`.
        case singleFile(path: String)
        /// A compiled class launched with the runtime classpath of the Gradle source set that
        /// holds `sourceFile`: `java -cp <classpath> pkg.Main`. The classes must have been built.
        case classpathMain(className: String, sourceFile: String)
    }

    /// Identifies the configuration in a project's list, across renames and edits.
    public var id: UUID
    /// What the user called it; `nil` shows ``displayName``.
    public var name: String?
    public var target: Target
    /// Arguments for the program. For Gradle they go to `--args`; for a single file they follow
    /// the file name, and are typed into the shell as written, so quoting works as usual.
    public var programArguments: String
    /// Options for the JVM (`-Xmx512m -Dkey=value`). Single-file launches only: Gradle's `run`
    /// task takes them from the build script, not the command line.
    public var vmArguments: String
    public var environment: [String: String]

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        target: Target,
        programArguments: String = "",
        vmArguments: String = "",
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.programArguments = programArguments
        self.vmArguments = vmArguments
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, target, programArguments, vmArguments, environment
    }

    /// Reads a configuration saved before configurations had an `id` and a `name`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name)
        target = try container.decode(Target.self, forKey: .target)
        programArguments = try container.decodeIfPresent(String.self, forKey: .programArguments) ?? ""
        vmArguments = try container.decodeIfPresent(String.self, forKey: .vmArguments) ?? ""
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }

    /// The name to list: the user's, else ``defaultName``.
    public var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultName : trimmed
    }

    /// A short description of the target: `Gradle run (:app)`, the file's name, or the class.
    public var defaultName: String {
        switch target {
        case .gradleRun(let projectPath):
            return projectPath == ":" ? "Gradle run" : "Gradle run (\(projectPath))"
        case .singleFile(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .classpathMain(let className, _):
            return className.split(separator: ".").last.map(String.init) ?? className
        }
    }

    /// Whether ``vmArguments`` can be passed to this target.
    public var supportsVMArguments: Bool {
        if case .gradleRun = target { return false }
        return true
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

    /// A launch of `file` with its compiled classes and the runtime classpath, for a file in a
    /// Gradle source set: `nil` when the file is not a `.java` file or the model has no source set
    /// for it. `source` supplies the `package` line, which the class name needs.
    public static func makeClasspathLaunch(file: URL, source: String, model: JavaGradleProjectModel?) -> JavaRunConfiguration? {
        guard file.pathExtension.lowercased() == "java", let model,
              model.runtimeClasspath(forFile: file) != nil else { return nil }
        let simpleName = file.deletingPathExtension().lastPathComponent
        let className = (packageName(in: source).map { $0 + "." } ?? "") + simpleName
        return JavaRunConfiguration(target: .classpathMain(className: className, sourceFile: file.path))
    }

    /// The name in the first `package a.b;` declaration, comments aside.
    static func packageName(in source: String) -> String? {
        var code = source
        code = code.replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: " ", options: .regularExpression)
        code = code.replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        guard let range = code.range(of: #"(?m)^\s*package\s+([A-Za-z_$][\w$]*(?:\s*\.\s*[A-Za-z_$][\w$]*)*)\s*;"#, options: .regularExpression) else {
            return nil
        }
        let declaration = String(code[range])
            .replacingOccurrences(of: #"^\s*package\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ";", with: "")
        return declaration.filter { !$0.isWhitespace }
    }

    /// The class output directories of `classpath` that do not exist yet, meaning nothing was
    /// built for them: a classpath launch would fail with `ClassNotFoundException` until a build
    /// runs. Resource directories are ignored, since a source set may have none.
    public static func missingClassDirectories(in classpath: [URL]) -> [URL] {
        classpath.filter { url in
            url.pathExtension.lowercased() != "jar"
                && url.path.contains("/classes/")
                && !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// This configuration's target with the arguments and environment of `previous`, when
    /// `previous` ran the same target: so running a file again keeps what was typed for it, and
    /// the same entry in the list is updated rather than a duplicate added.
    public func inheritingSettings(from previous: JavaRunConfiguration?) -> JavaRunConfiguration {
        guard let previous, previous.target == target else { return self }
        var result = self
        result.id = previous.id
        result.name = previous.name
        result.programArguments = previous.programArguments
        result.vmArguments = previous.vmArguments
        result.environment = previous.environment
        return result
    }
}

/// The run configurations of each project, kept in a small JSON file so they survive a restart:
/// a list (named ones are kept; runs of unnamed ones are remembered too, up to
/// ``maxUnnamedConfigurations``) and which one is selected, which is what Run Last
/// Configuration runs. Keyed by the project root's path (`""` for no project).
///
/// Reads the earlier format, one configuration per project, as a one-entry list.
///
/// Like ``GradleTrustStore`` it should live in a stable, non-cache location (Umbra uses
/// `~/Library/Application Support/<bundle id>/run-configurations.json`).
public final class JavaRunConfigurationStore: @unchecked Sendable {
    /// How many unnamed (automatically remembered) configurations a project keeps; the oldest go.
    public static let maxUnnamedConfigurations = 12

    private struct Entry: Codable {
        var configurations: [JavaRunConfiguration] = []
        var selected: UUID?
    }

    private struct File: Codable {
        var version = 2
        var projects: [String: Entry] = [:]
    }

    private let storeURL: URL
    private let lock = NSLock()
    private var projects: [String: Entry]

    public init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL) {
            if let file = try? JSONDecoder().decode(File.self, from: data), file.version >= 2 {
                projects = file.projects
            } else if let legacy = try? JSONDecoder().decode([String: JavaRunConfiguration].self, from: data) {
                projects = legacy.mapValues { Entry(configurations: [$0], selected: $0.id) }
            } else {
                projects = [:]
            }
        } else {
            projects = [:]
        }
    }

    /// The selected configuration: what the last Run used.
    public func last(forProject root: URL?) -> JavaRunConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = projects[key(for: root)] else { return nil }
        return entry.configurations.first { $0.id == entry.selected } ?? entry.configurations.last
    }

    /// Every configuration of the project, in the order they were created.
    public func configurations(forProject root: URL?) -> [JavaRunConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return projects[key(for: root)]?.configurations ?? []
    }

    /// Records `configuration` as the one just used or saved: it replaces the entry with the same
    /// `id` (keeping its place), or is added, and becomes the selected one.
    public func setLast(_ configuration: JavaRunConfiguration, forProject root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        var entry = projects[key(for: root)] ?? Entry()
        upsert(configuration, into: &entry)
        entry.selected = configuration.id
        trimUnnamed(&entry)
        projects[key(for: root)] = entry
        persist()
    }

    /// Adds or replaces `configuration` without changing which one is selected.
    public func save(_ configuration: JavaRunConfiguration, forProject root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        var entry = projects[key(for: root)] ?? Entry()
        upsert(configuration, into: &entry)
        if entry.selected == nil { entry.selected = configuration.id }
        projects[key(for: root)] = entry
        persist()
    }

    public func select(_ id: UUID, forProject root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = projects[key(for: root)], entry.configurations.contains(where: { $0.id == id }) else { return }
        entry.selected = id
        projects[key(for: root)] = entry
        persist()
    }

    /// Removes a configuration. When it was the selected one, the last remaining becomes selected.
    public func delete(_ id: UUID, forProject root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = projects[key(for: root)] else { return }
        entry.configurations.removeAll { $0.id == id }
        if entry.selected == id { entry.selected = entry.configurations.last?.id }
        projects[key(for: root)] = entry
        persist()
    }

    /// Adds a copy of a configuration named `<name> copy`, selects it, and returns it.
    @discardableResult
    public func duplicate(_ id: UUID, forProject root: URL?) -> JavaRunConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = projects[key(for: root)], let original = entry.configurations.first(where: { $0.id == id }) else {
            return nil
        }
        var copy = original
        copy.id = UUID()
        copy.name = original.displayName + " copy"
        entry.configurations.append(copy)
        entry.selected = copy.id
        projects[key(for: root)] = entry
        persist()
        return copy
    }

    private func upsert(_ configuration: JavaRunConfiguration, into entry: inout Entry) {
        if let index = entry.configurations.firstIndex(where: { $0.id == configuration.id }) {
            entry.configurations[index] = configuration
        } else {
            entry.configurations.append(configuration)
        }
    }

    /// Drops the oldest unnamed configurations beyond the cap, never the selected one.
    private func trimUnnamed(_ entry: inout Entry) {
        func isUnnamed(_ configuration: JavaRunConfiguration) -> Bool {
            configuration.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        var excess = entry.configurations.filter(isUnnamed).count - Self.maxUnnamedConfigurations
        guard excess > 0 else { return }
        let selected = entry.selected
        entry.configurations.removeAll { configuration in
            guard excess > 0, isUnnamed(configuration), configuration.id != selected else { return false }
            excess -= 1
            return true
        }
    }

    /// Caller must hold `lock`.
    private func persist() {
        guard let data = try? JSONEncoder().encode(File(projects: projects)) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private func key(for root: URL?) -> String {
        root?.standardizedFileURL.path ?? ""
    }
}
