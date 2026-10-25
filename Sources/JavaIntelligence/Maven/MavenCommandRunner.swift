import Foundation

/// Resolves the Maven executable for a project: the project's `mvnw` (searched upward as far as the
/// folder that holds `.mvn`), then the path from Settings, then `mvn` on a login shell's `PATH`.
/// A wrapper without the execute bit runs through `/bin/sh`.
public struct MavenExecutableResolver: Sendable {
    private var fileManager: FileManager { .default }
    private let processRunner: ProcessRunning

    public init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    /// `nil` when no Maven executable could be found.
    public func resolve(
        projectDirectory: URL,
        override: String? = nil
    ) -> (executable: URL, leadingArguments: [String])? {
        if let wrapper = wrapper(startingAt: projectDirectory) {
            return launch(wrapper)
        }
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fileManager.fileExists(atPath: url.path) { return launch(url) }
        }
        if let path = mavenOnPath() {
            return (URL(fileURLWithPath: path), [])
        }
        return nil
    }

    /// `mvnw` in `directory` or an ancestor, stopping at the ancestor that contains `.mvn`.
    private func wrapper(startingAt directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        while true {
            let wrapper = current.appendingPathComponent("mvnw")
            if fileManager.fileExists(atPath: wrapper.path) { return wrapper }
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: current.appendingPathComponent(".mvn").path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return nil
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    private func launch(_ url: URL) -> (executable: URL, leadingArguments: [String]) {
        if fileManager.isExecutableFile(atPath: url.path) { return (url, []) }
        return (URL(fileURLWithPath: "/bin/sh"), [url.path])
    }

    private func mavenOnPath() -> String? {
        guard let output = try? processRunner.run(executable: "/bin/zsh", arguments: ["-lc", "command -v mvn"]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Runs Maven for a trusted project. Indexing never comes through here: only goals, tests and
/// dependency downloads do. The process itself is ``SystemGradleProcessLauncher``.
public struct MavenCommandRunner: Sendable {
    private let trustStore: ProjectTrustStore
    private let launcher: GradleProcessLaunching
    private let resolver: MavenExecutableResolver

    public init(
        trustStore: ProjectTrustStore,
        launcher: GradleProcessLaunching = SystemGradleProcessLauncher(),
        resolver: MavenExecutableResolver = MavenExecutableResolver()
    ) {
        self.trustStore = trustStore
        self.launcher = launcher
        self.resolver = resolver
    }

    /// `projectDirectory` is the trust root and where `mvnw` is sought. `workingDirectory` is the
    /// process cwd (a download uses a temporary folder so the project's `.mvn/extensions.xml` is
    /// not loaded). `file` inserts `-f` before the goals.
    public func run(
        projectDirectory: URL,
        workingDirectory: URL? = nil,
        goals: [String],
        arguments: [String] = [],
        file: URL? = nil,
        javaHome: URL? = nil,
        executableOverride: String? = nil,
        settingsFile: URL? = nil,
        offline: Bool = false,
        timeout: Duration = .seconds(120),
        output: GradleOutputHandler? = nil
    ) async throws -> GradleCommandResult {
        guard trustStore.isTrusted(projectDirectory) else {
            throw GradleCommandError.untrusted(projectDirectory)
        }
        guard let resolved = resolver.resolve(projectDirectory: projectDirectory, override: executableOverride) else {
            throw GradleCommandError.executableNotFound
        }
        var environment = ProcessInfo.processInfo.environment
        if let javaHome { environment["JAVA_HOME"] = javaHome.path }
        var commandArguments = resolved.leadingArguments + ["-B", "-ntp"]
        if let settingsFile { commandArguments += ["-s", settingsFile.path] }
        if offline { commandArguments.append("-o") }
        if let file { commandArguments += ["-f", file.path] }
        commandArguments += goals + arguments
        let command = GradleCommand(
            executable: resolved.executable,
            arguments: commandArguments,
            currentDirectory: workingDirectory ?? projectDirectory,
            environment: environment
        )
        return try await launcher.launch(command, timeout: timeout, output: output)
    }
}
