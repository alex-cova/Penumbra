import Foundation

/// The Gradle init script (`--init-script`) that puts the JaCoCo agent on the JVM of every `Test`
/// and `JavaExec` (`run`, `bootRun`) task,
/// and the arguments that drive it.
///
/// The Gradle `jacoco` plugin is not used: it resolves `org.jacoco.*` from Maven at configuration
/// time (an offline or first run fails) and its version has to match the JDK. The agent jar Umbra
/// bundles is the same path a plain `main` takes.
///
/// A task whose project already applies the `jacoco` plugin is left alone: its own agent is the
/// one on the JVM (two agents would transform the same classes) and the script reports its
/// `.exec` file in a marker line, which ``execFiles(inOutput:)`` reads.
public enum JavaCoverageGradleScript {
    /// `##umbra-coverage|exec|<path>`: one per test task that will write coverage data, whoever
    /// put the agent there.
    public static let markerPrefix = "##umbra-coverage|exec|"

    public static let agentProperty = "umbraCoverageAgent"
    public static let directoryProperty = "umbraCoverageDir"
    public static let includesProperty = "umbraCoverageIncludes"

    /// A raw Swift string, so the Groovy backslashes are literal.
    public static let source = #"""
    import org.gradle.api.tasks.JavaExec
    import org.gradle.api.tasks.testing.Test

    allprojects { p ->
        // `run` and `bootRun` are JavaExec tasks; tests are Test tasks. Both start a JVM.
        def attach = { t ->
            if (!p.hasProperty('umbraCoverageAgent') || !p.hasProperty('umbraCoverageDir')) { return }
            t.doFirst {
                // Decided at execution, not configuration: the jacoco plugin adds its extension to
                // the task after this script's action has run.
                def own = t.extensions.findByName('jacoco')
                if (own != null && own.enabled) {
                    println('##umbra-coverage|exec|' + own.destinationFile)
                    return
                }
                String tag = (p.path == ':' ? 'root' : p.path.substring(1).replace(':', '_')) + '-' + t.name
                File dest = new File(p.property('umbraCoverageDir').toString(), tag + '.exec')
                String options = 'destfile=' + dest.path + ',append=true'
                if (p.hasProperty('umbraCoverageIncludes') && p.property('umbraCoverageIncludes').toString()) {
                    options += ',includes=' + p.property('umbraCoverageIncludes')
                }
                options += ',output=file'
                t.jvmArgs('-javaagent:' + p.property('umbraCoverageAgent') + '=' + options)
                println('##umbra-coverage|exec|' + dest.path)
            }
        }
        p.tasks.withType(JavaExec).configureEach { t -> attach(t) }
        p.tasks.withType(Test).configureEach { t ->
            if (!p.hasProperty('umbraCoverageAgent') || !p.hasProperty('umbraCoverageDir')) { return }
            // An up-to-date test task starts no JVM, and a cached one would replay old results.
            t.outputs.upToDateWhen { false }
            t.outputs.cacheIf { false }
            attach(t)
        }
    }
    """#

    /// The Gradle arguments for a run with coverage: the init script, the three properties, and
    /// the two switches that keep a cached or configuration-cached run from skipping the agent.
    public static func arguments(
        scriptURL: URL, agentJar: URL, executionDirectory: URL, includes: String?
    ) -> [String] {
        var result = [
            "--init-script", scriptURL.path,
            "-P\(agentProperty)=\(agentJar.path)",
            "-P\(directoryProperty)=\(executionDirectory.path)"
        ]
        if let includes, !includes.isEmpty { result.append("-P\(includesProperty)=\(includes)") }
        result += ["--no-configuration-cache", "--no-build-cache"]
        return result
    }

    /// The `.exec` files a run reported through ``markerPrefix`` lines, in the order seen, without
    /// repeats.
    public static func execFiles(inOutput output: String) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: markerPrefix) else { continue }
            let path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            result.append(URL(fileURLWithPath: path))
        }
        return result
    }
}
