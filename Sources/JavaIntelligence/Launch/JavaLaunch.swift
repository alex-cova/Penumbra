import Foundation

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
        gradleWrapperExists: Bool
    ) -> JavaLaunchCommand? {
        guard let configuration = JavaRunConfiguration.makeDefault(
            file: file, projectRoot: projectRoot, isGradleProject: isGradleProject, model: model
        ) else { return nil }
        return make(configuration: configuration, projectRoot: projectRoot, gradleWrapperExists: gradleWrapperExists)
    }

    /// The shell command for `configuration`. Environment variables become a `NAME='value'`
    /// prefix (names that aren't valid identifiers are dropped); a Gradle launch passes the
    /// program arguments as one quoted `--args`, and a single-file launch types the JVM and
    /// program arguments as written.
    public static func make(
        configuration: JavaRunConfiguration,
        projectRoot: URL?,
        gradleWrapperExists: Bool
    ) -> JavaLaunchCommand? {
        let environment = environmentPrefix(configuration.environment)
        switch configuration.target {
        case .gradleRun(let projectPath):
            guard let projectRoot else { return nil }
            var task = projectPath == ":" ? "run" : "\(projectPath):run"
            let arguments = configuration.programArguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if !arguments.isEmpty { task += " --args=\(shellQuote(arguments))" }
            return JavaLaunchCommand(shellCommand: gradleInvocation(
                task: task, projectRoot: projectRoot, gradleWrapperExists: gradleWrapperExists, environment: environment
            ))
        case .singleFile(let path):
            var parts = [environment.trimmingCharacters(in: .whitespaces), "java"]
            parts.append(configuration.vmArguments.trimmingCharacters(in: .whitespacesAndNewlines))
            parts.append(shellQuote(path))
            parts.append(configuration.programArguments.trimmingCharacters(in: .whitespacesAndNewlines))
            return JavaLaunchCommand(shellCommand: parts.filter { !$0.isEmpty }.joined(separator: " "))
        }
    }

    /// `./gradlew build` (or `gradle build`) at the project root. Builds every subproject.
    public static func build(projectRoot: URL, gradleWrapperExists: Bool) -> JavaLaunchCommand {
        JavaLaunchCommand(
            shellCommand: gradleInvocation(task: "build", projectRoot: projectRoot, gradleWrapperExists: gradleWrapperExists)
        )
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
}
