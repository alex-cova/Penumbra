import Foundation

/// A launch Umbra starts itself, as a program and its arguments rather than a shell command line,
/// so there is nothing to quote and a stop reaches the JVM.
public struct JavaProcessLaunch: Equatable, Sendable {
    /// The JDK's `bin/java`.
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    /// The child's whole environment.
    public var environment: [String: String]
    /// A text file to feed the program as standard input.
    public var redirectInput: URL?
    /// Files written for this launch (an `@argfile`); delete them when it ends.
    public var temporaryFiles: [URL]
    /// The launch as a shell would write it, for Copy Command Line. Not what runs.
    public var displayCommand: String

    public init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        redirectInput: URL? = nil,
        temporaryFiles: [URL] = [],
        displayCommand: String = ""
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.redirectInput = redirectInput
        self.temporaryFiles = temporaryFiles
        self.displayCommand = displayCommand
    }
}

extension JavaLaunchCommand {
    /// A classpath is moved into an `@argfile` past this many bytes when the configuration says
    /// `auto`: macOS allows about 1 MB of arguments and environment, but a long line is also hard to read.
    public static let argFileThreshold = 32_000

    /// The process that runs a ``JavaRunConfiguration/Target/classpathMain(className:sourceFile:)`` or
    /// ``JavaRunConfiguration/Target/singleFile(path:)`` configuration on the JDK at `javaHome`;
    /// `nil` for other targets, a class name that is not a plain Java name, or a missing classpath.
    ///
    /// The environment is `baseEnvironment`, then `JAVA_HOME` and the JDK's `bin` ahead of `PATH`,
    /// then the configuration's own variables, so one the user set wins. The program runs in the
    /// configuration's working directory, else the project folder, else the file's folder.
    ///
    /// With ``JavaRunConfiguration/ShortenCommandLine/argFile`` (or `auto` and a long classpath) on a
    /// JDK of 9 or later, `-cp <classpath>` is written to a file in `argFileDirectory` and the
    /// command line carries `@file`; the file is listed in ``JavaProcessLaunch/temporaryFiles``.
    public static func makeProcessLaunch(
        configuration: JavaRunConfiguration,
        javaHome: URL,
        runtimeClasspath: [URL]?,
        projectRoot: URL?,
        jdkFeatureVersion: Int? = nil,
        usesNewLaunchProtocol: Bool = false,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        argFileDirectory: URL = FileManager.default.temporaryDirectory
    ) -> JavaProcessLaunch? {
        let java = javaHome.appendingPathComponent("bin/java")
        var isSourceLaunch = false
        if case .singleFile = configuration.target { isSourceLaunch = true }
        let vmOptions = newLaunchProtocolArguments(
            usesNewLaunchProtocol: usesNewLaunchProtocol, jdkFeatureVersion: jdkFeatureVersion, sourceLaunch: isSourceLaunch
        ) + JavaCommandLine.split(configuration.vmArguments)
        let programArguments = JavaCommandLine.split(configuration.programArguments)
        var arguments: [String]
        var temporaryFiles: [URL] = []
        let sourceFolder: URL
        switch configuration.target {
        case .classpathMain(let className, let sourceFile):
            guard let runtimeClasspath, !runtimeClasspath.isEmpty,
                  className.range(of: #"^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$"#, options: .regularExpression) != nil else { return nil }
            let classpath = runtimeClasspath.map(\.path).joined(separator: ":")
            var classpathArguments = ["-cp", classpath]
            if shouldUseArgFile(configuration.shortenCommandLine, classpathLength: classpath.utf8.count, jdkFeatureVersion: jdkFeatureVersion) {
                let file = argFileDirectory.appendingPathComponent("umbra-\(UUID().uuidString).args")
                let contents = "-cp \(JavaCommandLine.argFileQuoted(classpath))\n"
                if (try? contents.write(to: file, atomically: true, encoding: .utf8)) != nil {
                    temporaryFiles.append(file)
                    classpathArguments = ["@\(file.path)"]
                }
            }
            arguments = vmOptions + classpathArguments + [className] + programArguments
            sourceFolder = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        case .singleFile(let path):
            arguments = vmOptions + [path] + programArguments
            sourceFolder = URL(fileURLWithPath: path).deletingLastPathComponent()
        case .gradleRun, .gradleTest:
            return nil
        }

        let workingDirectory: URL
        if let directory = configuration.workingDirectory, !directory.isEmpty {
            workingDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        } else {
            workingDirectory = projectRoot ?? sourceFolder
        }

        var environment = baseEnvironment
        environment["JAVA_HOME"] = javaHome.path
        let binPath = javaHome.appendingPathComponent("bin").path
        environment["PATH"] = [binPath, baseEnvironment["PATH"]].compactMap { $0 }.joined(separator: ":")
        let ownVariables = configuration.environment.filter {
            $0.key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
        }
        environment.merge(ownVariables) { _, own in own }

        let redirect = configuration.redirectInputPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let display = displayCommand(
            executable: java, arguments: arguments, workingDirectory: workingDirectory,
            variables: ownVariables, redirectInput: redirect
        )
        return JavaProcessLaunch(
            executable: java, arguments: arguments, workingDirectory: workingDirectory,
            environment: environment, redirectInput: redirect, temporaryFiles: temporaryFiles,
            displayCommand: display
        )
    }

    /// The first Java that can run an instance `main`, a `main` with no arguments, or a compact source file.
    public static let minimumJavaForNewLaunchProtocol = 21

    /// What a JDK needs to run such a program: nothing from Java 25 (JEP 512 made it final), the
    /// preview switch on 21 to 24 (and `--source` for the source launcher). Older JDKs cannot run
    /// it at all, which is for the caller to report. An unknown version gets nothing.
    public static func newLaunchProtocolArguments(usesNewLaunchProtocol: Bool, jdkFeatureVersion: Int?, sourceLaunch: Bool) -> [String] {
        guard usesNewLaunchProtocol, let version = jdkFeatureVersion, (minimumJavaForNewLaunchProtocol..<25).contains(version) else {
            return []
        }
        return sourceLaunch ? ["--enable-preview", "--source", String(version)] : ["--enable-preview"]
    }

    private static func shouldUseArgFile(
        _ choice: JavaRunConfiguration.ShortenCommandLine, classpathLength: Int, jdkFeatureVersion: Int?
    ) -> Bool {
        // `@argfiles` came with Java 9. An unknown version gets the plain command line.
        guard let jdkFeatureVersion, jdkFeatureVersion >= 9 else { return false }
        switch choice {
        case .none: return false
        case .argFile: return true
        case .auto: return classpathLength > argFileThreshold
        }
    }

    private static func displayCommand(
        executable: URL, arguments: [String], workingDirectory: URL, variables: [String: String], redirectInput: URL?
    ) -> String {
        func quoted(_ text: String) -> String {
            text.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil ? text : shellQuote(text)
        }
        var parts = ["cd \(quoted(workingDirectory.path)) &&"]
        parts += variables.sorted { $0.key < $1.key }.map { "\($0.key)=\(shellQuote($0.value))" }
        parts.append(quoted(executable.path))
        parts += arguments.map(quoted)
        if let redirectInput { parts.append("< \(quoted(redirectInput.path))") }
        return parts.joined(separator: " ")
    }
}
