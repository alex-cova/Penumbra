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
        if isGradleProject, let projectRoot {
            let task = gradleRunTask(file: file, model: model)
            return JavaLaunchCommand(
                shellCommand: gradleInvocation(task: task, projectRoot: projectRoot, gradleWrapperExists: gradleWrapperExists)
            )
        }
        guard let file, file.pathExtension.lowercased() == "java" else { return nil }
        return JavaLaunchCommand(shellCommand: "java \(shellQuote(file.path))")
    }

    /// `./gradlew build` (or `gradle build`) at the project root. Builds every subproject.
    public static func build(projectRoot: URL, gradleWrapperExists: Bool) -> JavaLaunchCommand {
        JavaLaunchCommand(
            shellCommand: gradleInvocation(task: "build", projectRoot: projectRoot, gradleWrapperExists: gradleWrapperExists)
        )
    }

    private static func gradleInvocation(task: String, projectRoot: URL, gradleWrapperExists: Bool) -> String {
        let launcher = gradleWrapperExists ? "./gradlew" : "gradle"
        return "cd \(shellQuote(projectRoot.path)) && \(launcher) \(task)"
    }

    private static func gradleRunTask(file: URL?, model: JavaGradleProjectModel?) -> String {
        guard let file, let match = model?.sourceSet(containing: file) else { return "run" }
        return match.subproject.path == ":" ? "run" : "\(match.subproject.path):run"
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
