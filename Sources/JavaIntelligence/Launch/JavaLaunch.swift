import Foundation

/// A launchable `main` found in a source file.
public struct JavaMainMethodLocation: Sendable, Equatable {
    /// 1-based line of the method name.
    public let line: Int
    /// The declaring type's own name, e.g. `Inner` for `a.Outer.Inner`.
    public let simpleClassName: String
    /// The name the JVM launches, e.g. `a.Outer$Inner`.
    public let binaryClassName: String
    /// `static void main(…)`, as opposed to an instance method of Java 21's instance main protocol.
    public let isStatic: Bool
    /// `main(String[] args)`, as opposed to the no-argument `main()`.
    public let takesArguments: Bool
    /// A method of a compact source file: it sits outside any class, and the file is the class.
    public let isImplicitClass: Bool

    public init(
        line: Int,
        simpleClassName: String,
        binaryClassName: String,
        isStatic: Bool = true,
        takesArguments: Bool = true,
        isImplicitClass: Bool = false
    ) {
        self.line = line
        self.simpleClassName = simpleClassName
        self.binaryClassName = binaryClassName
        self.isStatic = isStatic
        self.takesArguments = takesArguments
        self.isImplicitClass = isImplicitClass
    }

    /// Whether the JVM needs the launch protocol of JEP 445/512 (an instance `main`, a `main` with
    /// no arguments, or a compact source file) rather than the classic `public static void main(String[])`.
    /// Java 25 has it; 21 to 24 need `--enable-preview`; older JDKs cannot run it.
    public var usesNewLaunchProtocol: Bool {
        isImplicitClass || !isStatic || !takesArguments
    }
}

/// Whether a Java source declares a launchable `main`. Recognizes the classic `public static void
/// main(String[])` in either modifier order, and the instance forms of Java 21+ (`void main()`,
/// `void main(String[])`, `static void main()`, any access but `private`, in a non-abstract class).
/// Comments and string literals do not count.
public enum JavaMainMethod {
    /// A quick text check, for deciding on every edit whether Run applies; ``locations(in:fileName:)``
    /// is the exact answer.
    public static func containsMain(in source: String) -> Bool {
        let code = strippingCommentsAndStrings(source)
        guard let regex = try? NSRegularExpression(pattern: mainPattern) else { return false }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        for match in regex.matches(in: code, range: range) {
            guard let modifiers = Range(match.range(at: 1), in: code) else { return true }
            if code[modifiers].range(of: #"\bprivate\b"#, options: .regularExpression) == nil { return true }
        }
        return false
    }

    /// Every `main` that can start a program in `source`, nested types included, for the gutter's
    /// run buttons: one per class, the one the JVM would pick (static with arguments, then static
    /// without, then instance with arguments, then instance without). Parses the whole file, so keep
    /// it off the main thread. `fileName` names the class of a compact source file.
    public static func locations(in source: String, fileName: String? = nil) -> [JavaMainMethodLocation] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let packageName = JavaImportList(tree: tree).packageName
        var candidates: [Candidate] = []
        collectMains(in: tree.rootNode, packageName: packageName, fileName: fileName, into: &candidates)
        var best: [String: Candidate] = [:]
        for candidate in candidates {
            if let existing = best[candidate.location.binaryClassName], existing.rank <= candidate.rank { continue }
            best[candidate.location.binaryClassName] = candidate
        }
        return best.values.map(\.location).sorted { $0.line < $1.line }
    }

    private struct Candidate {
        /// 0 static with arguments … 3 instance without: lower wins.
        let rank: Int
        let location: JavaMainMethodLocation
    }

    private static let typeDeclarations: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration"
    ]

    private static func collectMains(
        in node: SyntaxNode, packageName: String, fileName: String?, into result: inout [Candidate]
    ) {
        if node.type == "method_declaration" {
            if let candidate = candidate(node, packageName: packageName, fileName: fileName) {
                result.append(candidate)
            }
            return
        }
        for child in node.namedChildren {
            collectMains(in: child, packageName: packageName, fileName: fileName, into: &result)
        }
    }

    private static func candidate(_ method: SyntaxNode, packageName: String, fileName: String?) -> Candidate? {
        guard let name = method.child(byFieldName: "name"), name.text == "main",
              method.child(byFieldName: "type")?.type == "void_type",
              let parameters = method.child(byFieldName: "parameters") else { return nil }
        let modifiers = method.firstNamedChild(ofType: "modifiers")?.children.map(\.type) ?? []
        guard !modifiers.contains("private") else { return nil }
        let isStatic = modifiers.contains("static")

        let declared = parameters.namedChildren.filter { $0.type == "formal_parameter" || $0.type == "spread_parameter" }
        let takesArguments: Bool
        switch declared.count {
        case 0: takesArguments = false
        case 1 where isStringArray(declared[0]): takesArguments = true
        default: return nil
        }

        // The instance forms need a class to create: not an interface, and not an abstract class.
        var owner = method.parent
        while let node = owner, !typeDeclarations.contains(node.type), node.type != "program" { owner = node.parent }
        if !isStatic, let owner, owner.type != "program" {
            if owner.type == "interface_declaration" || owner.type == "annotation_type_declaration" { return nil }
            if owner.firstNamedChild(ofType: "modifiers")?.children.contains(where: { $0.type == "abstract" }) == true { return nil }
        }

        let types = JavaTestDiscovery.enclosingTypeNames(of: method)
        let position = JavaTestDiscovery.lineColumn(forByteOffset: name.startByte, in: method.tree.sourceBytes)
        let rank = (isStatic ? 0 : 2) + (takesArguments ? 0 : 1)
        if let simpleName = types.last {
            let prefix = packageName.isEmpty ? "" : packageName + "."
            return Candidate(rank: rank, location: JavaMainMethodLocation(
                line: position.line + 1,
                simpleClassName: simpleName,
                binaryClassName: prefix + types.joined(separator: "$"),
                isStatic: isStatic,
                takesArguments: takesArguments
            ))
        }
        // Outside any class: a compact source file, whose class is named after the file.
        guard method.parent?.type == "program" else { return nil }
        let stem = fileName.map { ($0 as NSString).deletingPathExtension } ?? "Main"
        guard !stem.isEmpty else { return nil }
        return Candidate(rank: rank, location: JavaMainMethodLocation(
            line: position.line + 1,
            simpleClassName: stem,
            binaryClassName: stem,
            isStatic: isStatic,
            takesArguments: takesArguments,
            isImplicitClass: true
        ))
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

    /// Modifiers (captured, so `private` can be told apart), `void main(`, then no parameter or a
    /// `String[]` one. The parameter is checked loosely here; ``locations(in:fileName:)`` is exact.
    private static let mainPattern = #"""
    (?<![\w$.])((?:(?:public|protected|private|static|final|strictfp|synchronized|native)\s+)*)void\s+main\s*\(\s*(?:(?:final\s+)?(?:java\s*\.\s*lang\s*\.\s*)?String\s*(?:(?:\[\s*\]|\.\.\.)\s*[\w$]*|\s+[\w$]+\s*\[\s*\]))?\s*\)
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
        case .gradleTest(let taskPath, let filters, _):
            guard let projectRoot else { return nil }
            var task = taskPath
            for filter in filters where !filter.isEmpty { task += " --tests \(shellQuote(filter))" }
            return JavaLaunchCommand(shellCommand: gradleInvocation(
                task: task, projectRoot: projectRoot, gradleWrapperExists: gradleWrapperExists,
                environment: jdkEnvironment
            ))
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
    /// Where the program runs; `nil` is the debug adapter's own directory.
    public let workingDirectory: URL?
    /// A text file fed to the program as standard input.
    public let inputFile: URL?

    public init(
        javaExecutable: URL,
        vmArguments: [String],
        classpath: [URL],
        mainClass: String,
        programArguments: [String],
        environment: [String: String],
        jdwpPort: Int,
        suspendOnStart: Bool,
        workingDirectory: URL? = nil,
        inputFile: URL? = nil
    ) {
        self.javaExecutable = javaExecutable
        self.vmArguments = vmArguments
        self.classpath = classpath
        self.mainClass = mainClass
        self.programArguments = programArguments
        self.environment = environment
        self.jdwpPort = jdwpPort
        self.suspendOnStart = suspendOnStart
        self.workingDirectory = workingDirectory
        self.inputFile = inputFile
    }
}

extension JavaLaunchCommand {
    /// Builds a managed launch for the debugger, or `nil` when the configuration cannot be debugged.
    public static func makeManagedLaunch(
        configuration: JavaRunConfiguration,
        javaHome: URL,
        runtimeClasspath: [URL],
        jdwpPort: Int,
        projectRoot: URL? = nil,
        extraVMArguments: [String] = []
    ) -> JavaManagedLaunch? {
        guard configuration.launchMode == .debug,
              case .classpathMain(let className, _) = configuration.target,
              className.range(of: #"^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$"#, options: .regularExpression) != nil,
              !runtimeClasspath.isEmpty else { return nil }
        let java = javaHome.appendingPathComponent("bin/java")
        guard FileManager.default.isExecutableFile(atPath: java.path) else { return nil }
        var vm = extraVMArguments + JavaCommandLine.split(configuration.vmArguments.trimmingCharacters(in: .whitespacesAndNewlines))
        vm.append(jdwpAgent(port: jdwpPort, suspend: configuration.suspendOnStart))
        let program = JavaCommandLine.split(configuration.programArguments.trimmingCharacters(in: .whitespacesAndNewlines))
        return JavaManagedLaunch(
            javaExecutable: java,
            vmArguments: vm,
            classpath: runtimeClasspath,
            mainClass: className,
            programArguments: program,
            environment: configuration.environment,
            jdwpPort: jdwpPort,
            suspendOnStart: configuration.suspendOnStart,
            workingDirectory: configuration.workingDirectory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? projectRoot,
            inputFile: configuration.redirectInputPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        )
    }
}
