import Foundation

/// A program and its arguments, run without a shell.
public struct JavaToolInvocation: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// Builds the two commands coverage needs: the agent argument for the JVM that runs the code,
/// and the CLI call that turns what it wrote into a report. Everything is an argument vector.
public enum JavaCoverageCommand {
    /// The `includes` pattern list for the agent: the top-level packages of the project's own
    /// sources as `pkg.*` (subpackages match too), joined by `:`. Dependencies are not
    /// instrumented, which keeps start-up and overhead low.
    ///
    /// A class in the default package cannot be matched by a package pattern, so its name goes in
    /// as is. Returns `nil` when nothing narrows the set, so the caller instruments everything.
    public static func includes(packages: [String], defaultPackageClasses: [String] = []) -> String? {
        let named = Set(packages.filter { !$0.isEmpty })
        // Keep only packages no other chosen package is a prefix of.
        let roots = named.filter { candidate in
            !named.contains { other in other != candidate && candidate.hasPrefix(other + ".") }
        }
        var patterns = roots.sorted().map { $0 + ".*" }
        patterns += Set(defaultPackageClasses).sorted()
        return patterns.isEmpty ? nil : patterns.joined(separator: ":")
    }

    /// Whether `path` can sit inside an agent option string: JaCoCo splits options on commas and
    /// has no escape for one, and `=` ends the jar path.
    public static func isSafeForAgent(_ path: String) -> Bool {
        !path.contains(",") && !path.contains("\n")
    }

    /// `-javaagent:<jar>=destfile=<exec>,append=true,includes=…,output=file`.
    /// `append=true` lets several JVMs of one task (forks, a restarted daemon worker) share a file.
    /// `nil` for a path JaCoCo's option syntax cannot carry.
    public static func agentArgument(agentJar: URL, execFile: URL, includes: String? = nil) -> String? {
        guard isSafeForAgent(agentJar.path), !agentJar.path.contains("="), isSafeForAgent(execFile.path) else { return nil }
        if let includes, !isSafeForAgent(includes) { return nil }
        var options = ["destfile=\(execFile.path)", "append=true"]
        if let includes, !includes.isEmpty { options.append("includes=\(includes)") }
        options.append("output=file")
        return "-javaagent:\(agentJar.path)=" + options.joined(separator: ",")
    }

    /// `java -jar jacococli.jar report <exec…> --classfiles <dir>… --xml <out>`.
    ///
    /// Classes in `classDirectories` that nothing executed come out at 0 %, which is what makes
    /// untested files show up. `executionFiles` must all exist: the CLI throws on a missing one.
    public static func reportInvocation(
        java: URL,
        cliJar: URL,
        executionFiles: [URL],
        classDirectories: [URL],
        xmlOutput: URL,
        name: String? = nil
    ) -> JavaToolInvocation {
        var arguments = ["-jar", cliJar.path, "report"]
        arguments += executionFiles.map(\.path)
        for directory in classDirectories { arguments += ["--classfiles", directory.path] }
        arguments += ["--xml", xmlOutput.path]
        if let name, !name.isEmpty { arguments += ["--name", name] }
        return JavaToolInvocation(executable: java, arguments: arguments)
    }

    /// The HTML export: the same report with sources, for Export on the Coverage tab.
    public static func htmlInvocation(
        java: URL,
        cliJar: URL,
        executionFiles: [URL],
        classDirectories: [URL],
        sourceDirectories: [URL],
        htmlOutput: URL,
        name: String? = nil
    ) -> JavaToolInvocation {
        var arguments = ["-jar", cliJar.path, "report"]
        arguments += executionFiles.map(\.path)
        for directory in classDirectories { arguments += ["--classfiles", directory.path] }
        for directory in sourceDirectories { arguments += ["--sourcefiles", directory.path] }
        arguments += ["--html", htmlOutput.path]
        if let name, !name.isEmpty { arguments += ["--name", name] }
        return JavaToolInvocation(executable: java, arguments: arguments)
    }
}
