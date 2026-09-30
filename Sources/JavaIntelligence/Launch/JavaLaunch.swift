import Foundation

/// A launchable `main` found in a source file.
public struct JavaMainMethodLocation: Sendable, Equatable {
    /// 1-based line of the method name.
    public let line: Int
    /// The declaring type's own name, e.g. `Inner` for `a.Outer.Inner`.
    public let simpleClassName: String
    /// The name the JVM launches, e.g. `a.Outer$Inner`.
    public let binaryClassName: String

    public init(line: Int, simpleClassName: String, binaryClassName: String) {
        self.line = line
        self.simpleClassName = simpleClassName
        self.binaryClassName = binaryClassName
    }
}

/// Whether a Java source declares a launchable `main`. Recognizes `psvm` in either modifier order
/// (`public static void main` and `static public void main`). Comments and string literals do not count.
public enum JavaMainMethod {
    public static func containsMain(in source: String) -> Bool {
        let code = strippingCommentsAndStrings(source)
        guard let regex = try? NSRegularExpression(pattern: mainPattern) else { return false }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        for match in regex.matches(in: code, range: range) {
            guard let slice = Range(match.range, in: code) else { continue }
            if code[slice].range(of: #"\bstatic\b"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Every `static void main(String[] args)` declared in `source`, nested types included, for the
    /// gutter's run buttons. Parses the whole file, so keep it off the main thread.
    public static func locations(in source: String) -> [JavaMainMethodLocation] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let packageName = JavaImportList(tree: tree).packageName
        var result: [JavaMainMethodLocation] = []
        collectMains(in: tree.rootNode, packageName: packageName, into: &result)
        return result
    }

    private static func collectMains(in node: SyntaxNode, packageName: String, into result: inout [JavaMainMethodLocation]) {
        if node.type == "method_declaration" {
            if let location = mainLocation(node, packageName: packageName) {
                result.append(location)
            }
            return
        }
        for child in node.namedChildren {
            collectMains(in: child, packageName: packageName, into: &result)
        }
    }

    private static func mainLocation(_ method: SyntaxNode, packageName: String) -> JavaMainMethodLocation? {
        guard let name = method.child(byFieldName: "name"), name.text == "main",
              method.child(byFieldName: "type")?.type == "void_type",
              let modifiers = method.firstNamedChild(ofType: "modifiers"),
              modifiers.children.contains(where: { $0.type == "static" }),
              let parameters = method.child(byFieldName: "parameters") else { return nil }
        let declared = parameters.namedChildren.filter { $0.type == "formal_parameter" || $0.type == "spread_parameter" }
        guard declared.count == 1, isStringArray(declared[0]) else { return nil }
        let types = JavaTestDiscovery.enclosingTypeNames(of: method)
        guard let simpleName = types.last else { return nil }
        let prefix = packageName.isEmpty ? "" : packageName + "."
        let position = JavaTestDiscovery.lineColumn(forByteOffset: name.startByte, in: method.tree.sourceBytes)
        return JavaMainMethodLocation(
            line: position.line + 1,
            simpleClassName: simpleName,
            binaryClassName: prefix + types.joined(separator: "$")
        )
    }

    /// `String[] args`, `String args[]` or `String... args`, with `String` optionally qualified.
    private static func isStringArray(_ parameter: SyntaxNode) -> Bool {
        let typeNode = parameter.type == "spread_parameter"
            ? parameter.namedChildren.first { $0.type != "modifiers" && $0.type != "variable_declarator" }
            : parameter.child(byFieldName: "type")
        guard var type = typeNode?.text.filter({ !$0.isWhitespace }) else { return false }
        var dimensions = parameter.type == "spread_parameter" ? 1 : 0
        while type.hasSuffix("[]") {
            type.removeLast(2)
            dimensions += 1
        }
        if let declaredDimensions = parameter.child(byFieldName: "dimensions") {
            dimensions += declaredDimensions.text.filter { $0 == "[" }.count
        }
        return dimensions == 1 && (type == "String" || type == "java.lang.String")
    }

    /// One or more modifiers, then `void main(`. `static` is checked on the match so `public void main` does not qualify.
    private static let mainPattern = #"""
    \b(?:(?:public|protected|private|static|final|strictfp|synchronized|native)\s+)+void\s+main\s*\(
    """#

    private static func strippingCommentsAndStrings(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if character == "/", next < source.endIndex, source[next] == "/" {
                index = next
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                continue
            }
            if character == "/", next < source.endIndex, source[next] == "*" {
                index = source.index(after: next)
                while index < source.endIndex {
                    let after = source.index(after: index)
                    if source[index] == "*", after < source.endIndex, source[after] == "/" {
                        index = source.index(after: after)
                        break
                    }
                    index = after
                }
                continue
            }
            if character == "\"" || character == "'" {
                let quote = character
                index = next
                while index < source.endIndex {
                    if source[index] == "\\" {
                        let escaped = source.index(after: index)
                        index = escaped < source.endIndex ? source.index(after: escaped) : escaped
                        continue
                    }
                    if source[index] == quote {
                        index = source.index(after: index)
                        break
                    }
                    index = source.index(after: index)
                }
                result.append(" ")
                continue
            }
            result.append(character)
            index = next
        }
        return result
    }
}

/// Shell command for the toolbar play and hammer buttons. A Gradle project runs that project's
/// `run` task (`./gradlew run`, or `:app:run` when the file lives in a subproject) or `build` at
/// the project root. Anything else is a single-file `java` launch.
public struct JavaLaunchCommand: Equatable, Sendable {
    public let shellCommand: String

    public init(shellCommand: String) {
        self.shellCommand = shellCommand
    }

    public static func make(
        file: URL?,
        projectRoot: URL?,
        isGradleProject: Bool,
        model: JavaGradleProjectModel?,
        gradleWrapperExists: Bool,
        javaHome: URL? = nil
    ) -> JavaLaunchCommand? {
        guard let configuration = JavaRunConfiguration.makeDefault(
            file: file, projectRoot: projectRoot, isGradleProject: isGradleProject, model: model
        ) else { return nil }
        return make(
            configuration: configuration, projectRoot: projectRoot, gradleWrapperExists: gradleWrapperExists,
            javaHome: javaHome
        )
    }

    /// The shell command for `configuration`. Environment variables become a `NAME='value'`
    /// prefix (names that aren't valid identifiers are dropped); a Gradle launch passes the
    /// program arguments as one quoted `--args`, and a single-file launch types the JVM and
    /// program arguments as written.
    ///
    /// With a `javaHome`, a single-file or classpath launch runs that JDK's `bin/java`, and a Gradle
    /// launch gets `JAVA_HOME` and `PATH` for it ahead of the configuration's own environment, so
    /// a `JAVA_HOME` the user set on the configuration still wins. Without one, `java` and Gradle
    /// come from the shell's `PATH`.
    public static func make(
        configuration: JavaRunConfiguration,
        projectRoot: URL?,
        gradleWrapperExists: Bool,
        runtimeClasspath: [URL]? = nil,
        javaHome: URL? = nil
    ) -> JavaLaunchCommand? {
        let environment = environmentPrefix(configuration.environment)
        let java = javaHome.map { shellQuote($0.appendingPathComponent("bin/java").path) } ?? "java"
        let jdkEnvironment = javaHome.map(jdkEnvironmentPrefix) ?? ""
        switch configuration.target {
        case .gradleRun(let projectPath, let taskName):
            guard let projectRoot else { return nil }
            var task = gradleRunTask(for: projectPath, taskName: taskName ?? "run")
            let arguments = configuration.programArguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if !arguments.isEmpty { task += " --args=\(shellQuote(arguments))" }
            return JavaLaunchCommand(shellCommand: gradleInvocation(
                task: task, projectRoot: projectRoot, gradleWrapperExists: gradleWrapperExists,
                environment: jdkEnvironment + environment
            ))
        case .classpathMain(let className, _):
            // The class name goes into a shell command, so only a plain Java name is accepted.
            guard let runtimeClasspath, !runtimeClasspath.isEmpty,
                  className.range(of: #"^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$"#, options: .regularExpression) != nil else { return nil }
            let classpath = runtimeClasspath.map(\.path).joined(separator: ":")
            var parts = [environment.trimmingCharacters(in: .whitespaces), java]
            parts.append(configuration.vmArguments.trimmingCharacters(in: .whitespacesAndNewlines))
            parts.append("-cp")
            parts.append(shellQuote(classpath))
            parts.append(className)
            parts.append(configuration.programArguments.trimmingCharacters(in: .whitespacesAndNewlines))
            return JavaLaunchCommand(shellCommand: parts.filter { !$0.isEmpty }.joined(separator: " "))
        case .singleFile(let path):
            var parts = [environment.trimmingCharacters(in: .whitespaces), java]
            parts.append(configuration.vmArguments.trimmingCharacters(in: .whitespacesAndNewlines))
            parts.append(shellQuote(path))
            parts.append(configuration.programArguments.trimmingCharacters(in: .whitespacesAndNewlines))
            return JavaLaunchCommand(shellCommand: parts.filter { !$0.isEmpty }.joined(separator: " "))
        }
    }

    /// `./gradlew build` (or `gradle build`) at the project root. Builds every subproject.
    public static func build(projectRoot: URL, gradleWrapperExists: Bool, javaHome: URL? = nil) -> JavaLaunchCommand {
        JavaLaunchCommand(
            shellCommand: gradleInvocation(
                task: "build", projectRoot: projectRoot, gradleWrapperExists: gradleWrapperExists,
                environment: javaHome.map(jdkEnvironmentPrefix) ?? ""
            )
        )
    }

    /// `JAVA_HOME='…' PATH='…/bin':"$PATH" ` (with a trailing space). The path is spelled out
    /// because a prefix assignment can't see the one before it.
    private static func jdkEnvironmentPrefix(_ home: URL) -> String {
        "JAVA_HOME=\(shellQuote(home.path)) PATH=\(shellQuote(home.appendingPathComponent("bin").path)):\"$PATH\" "
    }

    private static func gradleInvocation(
        task: String, projectRoot: URL, gradleWrapperExists: Bool, environment: String = ""
    ) -> String {
        let launcher = gradleWrapperExists ? "./gradlew" : "gradle"
        return "cd \(shellQuote(projectRoot.path)) && \(environment)\(launcher) \(task)"
    }

    /// `A='1' B='two words' ` (with a trailing space), or `""`. Sorted, so the command is stable.
    private static func environmentPrefix(_ environment: [String: String]) -> String {
        environment
            .filter { $0.key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuote($0.value)) " }
            .joined()
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Splits a whitespace-separated JVM option string into tokens, respecting single quotes.
    static func splitVMArguments(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for character in text {
            if character == "'" {
                inQuote.toggle()
                continue
            }
            if character.isWhitespace, !inQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// JDWP agent flag for a debug launch.
    static func jdwpAgent(port: Int, suspend: Bool) -> String {
        "-agentlib:jdwp=transport=dt_socket,server=y,suspend=\(suspend ? "y" : "n"),address=*:\(port)"
    }

    /// The path of a subproject's task, `run` by default (`:` → `run`, `:app` → `:app:run`,
    /// `:app` and `bootRun` → `:app:bootRun`).
    public static func gradleRunTask(for projectPath: String, taskName: String = "run") -> String {
        projectPath == ":" ? taskName : "\(projectPath):\(taskName)"
    }

    /// Extra Gradle CLI flags for `runGradleTasks`, optionally including `--debug-jvm`.
    public static func gradleRunArguments(configuration: JavaRunConfiguration, debug: Bool = false) -> [String] {
        var arguments = ["--no-configuration-cache"]
        if debug { arguments.append("--debug-jvm") }
        let program = configuration.programArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !program.isEmpty { arguments.append("--args=\(shellQuote(program))") }
        return arguments
    }

    /// JDWP port used by Gradle's `--debug-jvm` flag (Application plugin default).
    public static let gradleDebugJdwpPort = 5005
}

/// A managed JVM launch (not a shell string) for Umbra's debugger.
public struct JavaManagedLaunch: Equatable, Sendable {
    public let javaExecutable: URL
    public let vmArguments: [String]
    public let classpath: [URL]
    public let mainClass: String
    public let programArguments: [String]
    public let environment: [String: String]
    public let jdwpPort: Int
    public let suspendOnStart: Bool

    public init(
        javaExecutable: URL,
        vmArguments: [String],
        classpath: [URL],
        mainClass: String,
        programArguments: [String],
        environment: [String: String],
        jdwpPort: Int,
        suspendOnStart: Bool
    ) {
        self.javaExecutable = javaExecutable
        self.vmArguments = vmArguments
        self.classpath = classpath
        self.mainClass = mainClass
        self.programArguments = programArguments
        self.environment = environment
        self.jdwpPort = jdwpPort
        self.suspendOnStart = suspendOnStart
    }
}

extension JavaLaunchCommand {
    /// Builds a managed launch for the debugger, or `nil` when the configuration cannot be debugged.
    public static func makeManagedLaunch(
        configuration: JavaRunConfiguration,
        javaHome: URL,
        runtimeClasspath: [URL],
        jdwpPort: Int
    ) -> JavaManagedLaunch? {
        guard configuration.launchMode == .debug,
              case .classpathMain(let className, _) = configuration.target,
              className.range(of: #"^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$"#, options: .regularExpression) != nil,
              !runtimeClasspath.isEmpty else { return nil }
        let java = javaHome.appendingPathComponent("bin/java")
        guard FileManager.default.isExecutableFile(atPath: java.path) else { return nil }
        var vm = splitVMArguments(configuration.vmArguments.trimmingCharacters(in: .whitespacesAndNewlines))
        vm.append(jdwpAgent(port: jdwpPort, suspend: configuration.suspendOnStart))
        let program = splitVMArguments(configuration.programArguments.trimmingCharacters(in: .whitespacesAndNewlines))
        return JavaManagedLaunch(
            javaExecutable: java,
            vmArguments: vm,
            classpath: runtimeClasspath,
            mainClass: className,
            programArguments: program,
            environment: configuration.environment,
            jdwpPort: jdwpPort,
            suspendOnStart: configuration.suspendOnStart
        )
    }
}
