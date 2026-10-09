import Foundation

/// Whether a configuration runs normally or under the debugger.
public enum JavaLaunchMode: String, Codable, Equatable, Sendable {
    case run
    case debug
}

/// How to launch a Java program: what to run, and the arguments and environment to run it with.
public struct JavaRunConfiguration: Codable, Equatable, Sendable {
    public enum Target: Codable, Equatable, Sendable {
        /// A Gradle run task of a project: `":"` for the root project, else `":app"` and so on.
        /// `taskName` is the task to run (`bootRun` for a Spring Boot app); `nil` means `run`, and
        /// is what configurations saved before it existed decode to.
        case gradleRun(projectPath: String, taskName: String? = nil)
        /// A single `.java` file launched with `java File.java`.
        case singleFile(path: String)
        /// A compiled class launched with the runtime classpath of the Gradle source set that
        /// holds `sourceFile`: `java -cp <classpath> pkg.Main`. The classes must have been built.
        case classpathMain(className: String, sourceFile: String)
        /// Tests run through a Gradle test task: `taskPath` is `:app:test`, `filters` are `--tests`
        /// patterns (none runs the whole task). `sourceFile` is the test file the run was made from,
        /// when there is one.
        case gradleTest(taskPath: String, filters: [String], sourceFile: String?)
    }

    /// The groups of the Edit Configurations list, and what a template is keyed by.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case application
        case javaFile
        case gradle
        case junit

        public var title: String {
            switch self {
            case .application: return "Application"
            case .javaFile: return "Java File"
            case .gradle: return "Gradle"
            case .junit: return "JUnit"
            }
        }
    }

    /// Something that runs before the program starts. A failure stops the launch.
    public enum BeforeLaunchTask: Codable, Equatable, Sendable {
        /// Gradle tasks, by path or name, run in one Gradle invocation.
        case gradleTasks([String])
        /// Another configuration of the project, run to its end first.
        case runConfiguration(UUID)
    }

    /// How a long classpath is kept off the command line.
    public enum ShortenCommandLine: String, Codable, Equatable, Sendable {
        /// An `@argfile` when the classpath is long and the JDK (9+) can read one.
        case auto
        case none
        /// Always an `@argfile`.
        case argFile
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
    /// Run in the terminal or launch under the debugger (classpath targets only in Umbra today).
    public var launchMode: JavaLaunchMode
    /// JDWP listen port for debug launches. `nil` lets the host pick a free port.
    public var jdwpPort: Int?
    /// When debugging, wait at startup until the debugger attaches.
    public var suspendOnStart: Bool
    /// Made by running something without saving it: the picker shows it faded, and only the newest
    /// few are kept. Save Configuration clears it. An unnamed configuration is temporary unless said
    /// otherwise, which is also what files saved before the flag existed decode to.
    public var isTemporary: Bool
    /// Kept in `<project>/.umbra/runConfigurations` instead of this Mac's store, so it can be
    /// committed and shared.
    public var storeAsProjectFile: Bool
    /// A group in the Edit Configurations list.
    public var folder: String?
    /// Where the program runs; `nil` is the project folder.
    public var workingDirectory: String?
    /// The JDK to run on (its home); `nil` is the project's JDK. Never written to a project file,
    /// since a path to a JDK means nothing on another machine.
    public var jdkHome: String?
    /// Build the module's classes before every launch. Off, a build only happens when class
    /// directories are missing.
    public var buildBeforeRun: Bool
    /// Start another instance while one of this configuration is still running, instead of
    /// stopping the first.
    public var allowMultipleInstances: Bool
    public var beforeLaunch: [BeforeLaunchTask]
    public var shortenCommandLine: ShortenCommandLine
    /// A text file whose contents become the program's standard input.
    public var redirectInputPath: String?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        target: Target,
        programArguments: String = "",
        vmArguments: String = "",
        environment: [String: String] = [:],
        launchMode: JavaLaunchMode = .run,
        jdwpPort: Int? = nil,
        suspendOnStart: Bool = true,
        isTemporary: Bool? = nil,
        storeAsProjectFile: Bool = false,
        folder: String? = nil,
        workingDirectory: String? = nil,
        jdkHome: String? = nil,
        buildBeforeRun: Bool = true,
        allowMultipleInstances: Bool = false,
        beforeLaunch: [BeforeLaunchTask] = [],
        shortenCommandLine: ShortenCommandLine = .auto,
        redirectInputPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.programArguments = programArguments
        self.vmArguments = vmArguments
        self.environment = environment
        self.launchMode = launchMode
        self.jdwpPort = jdwpPort
        self.suspendOnStart = suspendOnStart
        self.isTemporary = isTemporary ?? Self.isBlank(name)
        self.storeAsProjectFile = storeAsProjectFile
        self.folder = folder
        self.workingDirectory = workingDirectory
        self.jdkHome = jdkHome
        self.buildBeforeRun = buildBeforeRun
        self.allowMultipleInstances = allowMultipleInstances
        self.beforeLaunch = beforeLaunch
        self.shortenCommandLine = shortenCommandLine
        self.redirectInputPath = redirectInputPath
    }

    private static func isBlank(_ name: String?) -> Bool {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, target, programArguments, vmArguments, environment
        case launchMode, jdwpPort, suspendOnStart
        case isTemporary, storeAsProjectFile, folder, workingDirectory, jdkHome
        case buildBeforeRun, allowMultipleInstances, beforeLaunch, shortenCommandLine, redirectInputPath
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
        launchMode = try container.decodeIfPresent(JavaLaunchMode.self, forKey: .launchMode) ?? .run
        jdwpPort = try container.decodeIfPresent(Int.self, forKey: .jdwpPort)
        suspendOnStart = try container.decodeIfPresent(Bool.self, forKey: .suspendOnStart) ?? true
        isTemporary = try container.decodeIfPresent(Bool.self, forKey: .isTemporary) ?? Self.isBlank(name)
        storeAsProjectFile = try container.decodeIfPresent(Bool.self, forKey: .storeAsProjectFile) ?? false
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        jdkHome = try container.decodeIfPresent(String.self, forKey: .jdkHome)
        buildBeforeRun = try container.decodeIfPresent(Bool.self, forKey: .buildBeforeRun) ?? true
        allowMultipleInstances = try container.decodeIfPresent(Bool.self, forKey: .allowMultipleInstances) ?? false
        beforeLaunch = try container.decodeIfPresent([BeforeLaunchTask].self, forKey: .beforeLaunch) ?? []
        shortenCommandLine = try container.decodeIfPresent(ShortenCommandLine.self, forKey: .shortenCommandLine) ?? .auto
        redirectInputPath = try container.decodeIfPresent(String.self, forKey: .redirectInputPath)
    }

    /// The name to list: the user's, else ``defaultName``.
    public var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultName : trimmed
    }

    /// Which group of the Edit Configurations list this belongs to.
    public var kind: Kind {
        switch target {
        case .gradleRun: return .gradle
        case .singleFile: return .javaFile
        case .classpathMain: return .application
        case .gradleTest: return .junit
        }
    }

    /// A short description of the target: `Gradle run (:app)`, the file's name, or the class.
    public var defaultName: String {
        switch target {
        case .gradleRun(let projectPath, let taskName):
            let label = "Gradle \(taskName ?? "run")"
            return projectPath == ":" ? label : "\(label) (\(projectPath))"
        case .singleFile(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .classpathMain(let className, _):
            return className.split(separator: ".").last.map(String.init) ?? className
        case .gradleTest(let taskPath, let filters, _):
            guard let filter = filters.first else {
                let project = taskPath.split(separator: ":", omittingEmptySubsequences: false).dropLast().joined(separator: ":")
                return "All tests (\(project.isEmpty ? ":" : project))"
            }
            // `app.FooTest` or `app.FooTest.testAdds`: the class, and the method when a filter names one.
            let parts = filter.split(separator: ".").map(String.init)
            let simple = filters.count == 1 ? Self.testFilterLabel(parts) : "\(Self.testFilterLabel(parts)) +\(filters.count - 1)"
            return simple
        }
    }

    /// `FooTest` for `app.FooTest`, `FooTest.testAdds` for `app.FooTest.testAdds`: a method name
    /// starts lowercase, a class name does not.
    private static func testFilterLabel(_ parts: [String]) -> String {
        guard let last = parts.last else { return "" }
        if let first = last.first, first.isLowercase, parts.count >= 2 {
            return "\(parts[parts.count - 2]).\(last)"
        }
        return last
    }

    /// The configuration that runs `scope`: a Gradle test task filtered to its class or method.
    public static func makeTestLaunch(scope: JavaTestRunScope) -> JavaRunConfiguration {
        switch scope {
        case .allInModule(let taskPath):
            return JavaRunConfiguration(target: .gradleTest(taskPath: taskPath, filters: [], sourceFile: nil))
        case .testClass(let testClass):
            return JavaRunConfiguration(target: .gradleTest(
                taskPath: testClass.gradleTaskPath, filters: [testClass.qualifiedName], sourceFile: testClass.sourceFile.path
            ))
        case .testMethod(let method, let taskPath):
            return JavaRunConfiguration(target: .gradleTest(
                taskPath: taskPath, filters: [method.gradleTestFilter(includeMethod: true)], sourceFile: method.sourceFile.path
            ))
        case .tests(let taskPath, let filters):
            return JavaRunConfiguration(target: .gradleTest(taskPath: taskPath, filters: filters, sourceFile: nil))
        }
    }

    /// The scope a ``Target/gradleTest(taskPath:filters:sourceFile:)`` target runs; `nil` for the others.
    public var testScope: JavaTestRunScope? {
        guard case .gradleTest(let taskPath, let filters, _) = target else { return nil }
        return filters.isEmpty ? .allInModule(gradleTaskPath: taskPath) : .tests(taskPath: taskPath, filters: filters)
    }

    /// `path` with `transform` applied to every file path the configuration holds.
    public func mappingPaths(_ transform: (String) -> String) -> JavaRunConfiguration {
        var result = self
        switch target {
        case .gradleRun: break
        case .singleFile(let path): result.target = .singleFile(path: transform(path))
        case .classpathMain(let className, let sourceFile):
            result.target = .classpathMain(className: className, sourceFile: transform(sourceFile))
        case .gradleTest(let taskPath, let filters, let sourceFile):
            result.target = .gradleTest(taskPath: taskPath, filters: filters, sourceFile: sourceFile.map(transform))
        }
        result.workingDirectory = workingDirectory.map(transform)
        result.redirectInputPath = redirectInputPath.map(transform)
        return result
    }

    /// The Gradle task a ``Target/gradleRun(projectPath:taskName:)`` target runs, `run` by default;
    /// `nil` for other targets.
    public var gradleTaskName: String? {
        guard case .gradleRun(_, let taskName) = target else { return nil }
        return taskName ?? "run"
    }

    /// Whether ``vmArguments`` can be passed to this target.
    public var supportsVMArguments: Bool {
        switch target {
        case .gradleRun, .gradleTest: return false
        case .singleFile, .classpathMain: return true
        }
    }

    /// Whether ``environment`` reaches the program: only the launches Umbra starts itself do, since
    /// Gradle's tasks run in a daemon that has its own.
    public var supportsEnvironment: Bool {
        switch target {
        case .singleFile, .classpathMain: return true
        case .gradleRun, .gradleTest: return false
        }
    }

    /// Whether ``workingDirectory`` and ``redirectInputPath`` apply (the same launches as ``supportsEnvironment``).
    public var supportsWorkingDirectory: Bool { supportsEnvironment }

    /// Whether ``buildBeforeRun`` means anything: only a compiled class has a build to skip.
    public var supportsBuildBeforeRun: Bool {
        if case .classpathMain = target { return true }
        return false
    }

    /// Whether Umbra can launch this configuration under the debugger.
    public var supportsDebugLaunch: Bool {
        switch target {
        case .classpathMain, .gradleRun, .gradleTest: return true
        case .singleFile: return false
        }
    }

    /// A new configuration for `target` that starts from this one's settings, as a template does:
    /// a fresh identity and no name, everything else kept.
    public func instantiating(target: Target, name: String? = nil) -> JavaRunConfiguration {
        var result = self
        result.id = UUID()
        result.name = name
        result.target = target
        result.isTemporary = false
        return result
    }

    /// The template a project starts from before the user edits it, for configurations of `kind`.
    public static func defaultTemplate(for kind: Kind) -> JavaRunConfiguration {
        let target: Target
        switch kind {
        case .application: target = .classpathMain(className: "", sourceFile: "")
        case .javaFile: target = .singleFile(path: "")
        case .gradle: target = .gradleRun(projectPath: ":")
        case .junit: target = .gradleTest(taskPath: ":test", filters: [], sourceFile: nil)
        }
        // A fixed identity per kind, so two defaults compare equal and "unchanged" can be told from "edited".
        let identity = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(Kind.allCases.firstIndex(of: kind) ?? 0)") ?? UUID()
        return JavaRunConfiguration(id: identity, target: target, isTemporary: false)
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

    /// Which task Run uses for a Gradle subproject.
    public enum GradleRunTaskChoice: Equatable, Sendable {
        /// The subproject has this task: `run`, else `bootRun`.
        case task(String)
        /// No synced task list for the subproject: Run falls back to `run`.
        case unsynced
        /// The subproject has tasks, but neither `run` nor `bootRun`: the user picks one of these.
        case ask([JavaGradleProjectModel.GradleTask])
    }

    /// `run` when the subproject at `projectPath` has one, else `bootRun` (a Spring Boot app), else
    /// ``GradleRunTaskChoice/ask(_:)`` with its tasks. ``GradleRunTaskChoice/unsynced`` without a
    /// model or a task list for it.
    public static func preferredGradleRunTask(
        for projectPath: String, model: JavaGradleProjectModel?
    ) -> GradleRunTaskChoice {
        guard let tasks = model?.subprojects.first(where: { $0.path == projectPath })?.tasks, !tasks.isEmpty else {
            return .unsynced
        }
        for name in ["run", "bootRun"] where tasks.contains(where: { $0.name == name }) {
            return .task(name)
        }
        return .ask(tasks)
    }

    /// The Gradle subproject Run launches for `file`: the one whose source set holds it, else the root.
    public static func gradleProjectPath(for file: URL?, model: JavaGradleProjectModel?) -> String {
        file.flatMap { model?.sourceSet(containing: $0)?.subproject.path } ?? ":"
    }

    /// The configuration Run uses for `file` before the user edits anything: in a Gradle project,
    /// the file's subproject's `run` task, or `bootRun` when it has no `run`; else a single-file
    /// launch. `nil` for a synced Gradle subproject that has neither task: the host asks which to run.
    public static func makeDefault(
        file: URL?,
        projectRoot: URL?,
        isGradleProject: Bool,
        model: JavaGradleProjectModel?
    ) -> JavaRunConfiguration? {
        if isGradleProject, projectRoot != nil {
            let path = gradleProjectPath(for: file, model: model)
            switch preferredGradleRunTask(for: path, model: model) {
            case .task(let name):
                return JavaRunConfiguration(target: .gradleRun(projectPath: path, taskName: name == "run" ? nil : name))
            case .unsynced:
                return JavaRunConfiguration(target: .gradleRun(projectPath: path))
            case .ask:
                return nil
            }
        }
        guard let file, file.pathExtension.lowercased() == "java" else { return nil }
        return JavaRunConfiguration(target: .singleFile(path: file.path))
    }

    /// A launch of `file` with its compiled classes and the runtime classpath, for a file in a
    /// Gradle source set: `nil` when the file is not a `.java` file or the model has no source set
    /// for it. `source` supplies the `package` line, which the class name needs.
    public static func makeClasspathLaunch(file: URL, source: String, model: JavaGradleProjectModel?) -> JavaRunConfiguration? {
        let simpleName = file.deletingPathExtension().lastPathComponent
        let className = (packageName(in: source).map { $0 + "." } ?? "") + simpleName
        return makeClasspathLaunch(file: file, className: className, model: model)
    }

    /// A classpath launch of `className` (a binary name, `a.Outer$Inner` for a nested type)
    /// declared in `file`, under the same conditions as ``makeClasspathLaunch(file:source:model:)``.
    public static func makeClasspathLaunch(file: URL, className: String, model: JavaGradleProjectModel?) -> JavaRunConfiguration? {
        guard file.pathExtension.lowercased() == "java", let model,
              model.runtimeClasspath(forFile: file) != nil else { return nil }
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
        result.launchMode = previous.launchMode
        result.jdwpPort = previous.jdwpPort
        result.suspendOnStart = previous.suspendOnStart
        result.isTemporary = previous.isTemporary
        result.storeAsProjectFile = previous.storeAsProjectFile
        result.folder = previous.folder
        result.workingDirectory = previous.workingDirectory
        result.jdkHome = previous.jdkHome
        result.buildBeforeRun = previous.buildBeforeRun
        result.allowMultipleInstances = previous.allowMultipleInstances
        result.beforeLaunch = previous.beforeLaunch
        result.shortenCommandLine = previous.shortenCommandLine
        result.redirectInputPath = previous.redirectInputPath
        return result
    }
}

/// The run configurations of each project, kept in a small JSON file so they survive a restart:
/// a list (saved ones are kept; temporary ones, made by running something, are remembered too, up
/// to a limit) and which one is selected, which is what Run Last Configuration runs. Templates, one
/// per ``JavaRunConfiguration/Kind``, are the settings a new configuration starts from.
///
/// This holds only what stays on this Mac; ``JavaRunConfigurationCatalog`` adds the configurations
/// a project keeps in its own folder. Keyed by the project root's path (`""` for no project).
///
/// Reads the earlier format, one configuration per project, as a one-entry list.
///
/// Like ``GradleTrustStore`` it should live in a stable, non-cache location (Umbra uses
/// `~/Library/Application Support/<bundle id>/run-configurations.json`).
public final class JavaRunConfigurationStore: @unchecked Sendable {
    /// How many temporary configurations a project keeps unless told otherwise; the oldest go.
    public static let defaultTemporaryLimit = 5

    private struct Entry: Codable {
        var configurations: [JavaRunConfiguration] = []
        var selected: UUID?
        /// `JavaRunConfiguration.Kind.rawValue` to the template; absent in files saved before templates.
        var templates: [String: JavaRunConfiguration]?
    }

    private struct File: Codable {
        var version = 2
        var projects: [String: Entry] = [:]
    }

    private let storeURL: URL
    private let lock = NSLock()
    private var projects: [String: Entry]
    private var stamp: FileChangeStamp

    public init(storeURL: URL) {
        self.storeURL = storeURL
        projects = Self.load(storeURL) ?? [:]
        stamp = FileChangeStamp(url: storeURL)
    }

    /// Nil when the file is missing or unreadable. Reads the older one-configuration-per-project
    /// format too.
    private static func load(_ url: URL) -> [String: Entry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let file = try? JSONDecoder().decode(File.self, from: data), file.version >= 2 {
            return file.projects
        }
        if let legacy = try? JSONDecoder().decode([String: JavaRunConfiguration].self, from: data) {
            return legacy.mapValues { Entry(configurations: [$0], selected: $0.id) }
        }
        return nil
    }

    /// Picks up what another window's store or another process wrote since this one read the file,
    /// so a write here does not drop it. A file that cannot be read keeps what is in memory.
    /// Caller must hold `lock`.
    private func reloadIfChangedOnDisk() {
        guard stamp.hasChanged(at: storeURL) else { return }
        stamp.update(at: storeURL)
        if let loaded = Self.load(storeURL) {
            projects = loaded
        }
    }

    /// The selected configuration: what the last Run used.
    public func last(forProject root: URL?) -> JavaRunConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        guard let entry = projects[key(for: root)] else { return nil }
        return entry.configurations.first { $0.id == entry.selected } ?? entry.configurations.last
    }

    /// Every configuration of the project, in the order they were created.
    public func configurations(forProject root: URL?) -> [JavaRunConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        return projects[key(for: root)]?.configurations ?? []
    }

    /// Records `configuration` as the one just used or saved: it replaces the entry with the same
    /// `id` (keeping its place), or is added, and becomes the selected one.
    public func setLast(
        _ configuration: JavaRunConfiguration,
        forProject root: URL?,
        temporaryLimit: Int = JavaRunConfigurationStore.defaultTemporaryLimit
    ) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        var entry = projects[key(for: root)] ?? Entry()
        upsert(configuration, into: &entry)
        entry.selected = configuration.id
        trimTemporary(&entry, limit: temporaryLimit)
        projects[key(for: root)] = entry
        persist()
    }

    /// Adds or replaces `configuration` without changing which one is selected.
    public func save(_ configuration: JavaRunConfiguration, forProject root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        var entry = projects[key(for: root)] ?? Entry()
        upsert(configuration, into: &entry)
        if entry.selected == nil { entry.selected = configuration.id }
        projects[key(for: root)] = entry
        persist()
    }

    public func select(_ id: UUID, forProject root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        guard var entry = projects[key(for: root)], entry.configurations.contains(where: { $0.id == id }) else { return }
        entry.selected = id
        projects[key(for: root)] = entry
        persist()
    }

    /// Removes a configuration. When it was the selected one, the last remaining becomes selected.
    public func delete(_ id: UUID, forProject root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
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
        reloadIfChangedOnDisk()
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

    /// Selects `id` even when it is not in this store: a configuration the project keeps in its own
    /// folder is selected the same way.
    public func setSelected(_ id: UUID, forProject root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        var entry = projects[key(for: root)] ?? Entry()
        entry.selected = id
        projects[key(for: root)] = entry
        persist()
    }

    /// The id of the selected configuration, whether or not this store holds it.
    public func selectedID(forProject root: URL?) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        return projects[key(for: root)]?.selected
    }

    /// The settings new configurations of `kind` start from: what the user saved, else the defaults.
    public func template(for kind: JavaRunConfiguration.Kind, forProject root: URL?) -> JavaRunConfiguration {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        return projects[key(for: root)]?.templates?[kind.rawValue] ?? JavaRunConfiguration.defaultTemplate(for: kind)
    }

    public func setTemplate(_ template: JavaRunConfiguration, forProject root: URL?) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        var entry = projects[key(for: root)] ?? Entry()
        var templates = entry.templates ?? [:]
        var stored = template
        stored.isTemporary = false
        templates[template.kind.rawValue] = stored
        entry.templates = templates
        projects[key(for: root)] = entry
        persist()
    }

    private func upsert(_ configuration: JavaRunConfiguration, into entry: inout Entry) {
        if let index = entry.configurations.firstIndex(where: { $0.id == configuration.id }) {
            entry.configurations[index] = configuration
        } else {
            entry.configurations.append(configuration)
        }
    }

    /// Drops the oldest temporary configurations beyond `limit`, never the selected one.
    private func trimTemporary(_ entry: inout Entry, limit: Int) {
        var excess = entry.configurations.filter(\.isTemporary).count - max(0, limit)
        guard excess > 0 else { return }
        let selected = entry.selected
        entry.configurations.removeAll { configuration in
            guard excess > 0, configuration.isTemporary, configuration.id != selected else { return false }
            excess -= 1
            return true
        }
    }

    /// Caller must hold `lock`.
    private func persist() {
        guard let data = try? JSONEncoder().encode(File(projects: projects)) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
        stamp.update(at: storeURL)
    }

    private func key(for root: URL?) -> String {
        root?.standardizedFileURL.path ?? ""
    }
}
