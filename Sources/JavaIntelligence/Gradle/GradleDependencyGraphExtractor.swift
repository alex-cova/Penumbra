import Foundation

public enum GradleDependencyGraphError: Error, Sendable {
    /// The Gradle invocation exited non-zero.
    case failed(GradleCommandResult)
    /// Gradle exited zero but never wrote the graph.
    case missingOutput(GradleCommandResult)
    case decodingFailed(underlying: String, result: GradleCommandResult)
    /// The project has no such configuration, or resolving it threw.
    case unavailable(String)
}

/// Runs ``GradleDependencyGraphScript`` through ``GradleCommandRunner`` and decodes the library graph of
/// one project. Like ``GradleProjectModelExtractor`` it needs a trusted project and a JDK Gradle accepts.
public struct GradleDependencyGraphExtractor: Sendable {
    private let runner: GradleCommandRunner

    public init(runner: GradleCommandRunner) {
        self.runner = runner
    }

    /// The task path the script registers for a project: `:app` runs `:app:umbraDependencyGraph`.
    static func taskPath(forProject projectPath: String) -> String {
        projectPath == ":" || projectPath.isEmpty ? ":umbraDependencyGraph" : projectPath + ":umbraDependencyGraph"
    }

    public static let defaultConfiguration = "runtimeClasspath"

    public func extract(
        projectDirectory: URL,
        projectPath: String = ":",
        configuration: String = GradleDependencyGraphExtractor.defaultConfiguration,
        javaHome: URL?,
        timeout: Duration = .seconds(180),
        output: GradleOutputHandler? = nil
    ) async throws -> GradleDependencyGraph {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-gradle-deps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let scriptURL = workDirectory.appendingPathComponent("umbra-dependency-graph.init.gradle")
        try GradleDependencyGraphScript.source.write(to: scriptURL, atomically: true, encoding: .utf8)
        let outputURL = workDirectory.appendingPathComponent("dependencies.json")

        let result = try await runner.run(
            projectDirectory: projectDirectory,
            tasks: [Self.taskPath(forProject: projectPath)],
            arguments: [
                "--init-script", scriptURL.path,
                "--no-configuration-cache",
                "-PumbraDependencyOutput=\(outputURL.path)",
                "-PumbraDependencyConfiguration=\(configuration)"
            ],
            javaHome: javaHome,
            timeout: timeout,
            output: output
        )
        guard result.exitCode == 0 else { throw GradleDependencyGraphError.failed(result) }
        guard let data = try? Data(contentsOf: outputURL) else { throw GradleDependencyGraphError.missingOutput(result) }
        let graph: GradleDependencyGraph
        do {
            graph = try JSONDecoder().decode(GradleDependencyGraph.self, from: data)
        } catch {
            throw GradleDependencyGraphError.decodingFailed(underlying: String(describing: error), result: result)
        }
        if let message = graph.error, graph.components.isEmpty { throw GradleDependencyGraphError.unavailable(message) }
        return graph.limited()
    }
}
