import Foundation

public enum GradleProjectModelExtractionError: Error, Sendable {
    /// The Gradle invocation itself failed (non-zero exit). Carries the full result so a caller
    /// (Umbra's status bar / Gradle output panel) can show `stderr` instead of just "sync failed".
    case syncFailed(GradleCommandResult)
    /// The invocation exited zero but never wrote the model file.
    case missingOutput(GradleCommandResult)
    /// The model file was written but couldn't be decoded as ``JavaGradleProjectModel``.
    case decodingFailed(underlying: String, result: GradleCommandResult)
}

/// Runs ``GradleProjectModelScript`` against a project via ``GradleCommandRunner`` and decodes its
/// JSON output into a ``JavaGradleProjectModel``.
public struct GradleProjectModelExtractor: Sendable {
    private let runner: GradleCommandRunner

    public init(runner: GradleCommandRunner) {
        self.runner = runner
    }

    /// Whether `url` looks like the root of a Gradle project: a settings/build script or the
    /// wrapper script at the top level. Used to decide whether to attempt extraction at all before
    /// ever touching the trust store or spawning a process.
    public static func isGradleProject(_ url: URL) -> Bool {
        let markers = [
            "settings.gradle", "settings.gradle.kts",
            "build.gradle", "build.gradle.kts",
            "gradlew"
        ]
        let fileManager = FileManager.default
        return markers.contains { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// Extracts the project model for `projectDirectory`, running the init script through
    /// `GradleCommandRunner.run(...)` as
    /// `./gradlew :umbraProjectModel -PumbraModelOutput=... --init-script ...`.
    public func extract(
        projectDirectory: URL,
        javaHome: URL?,
        timeout: Duration = .seconds(120)
    ) async throws -> (model: JavaGradleProjectModel, result: GradleCommandResult) {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-gradle-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let scriptURL = workDirectory.appendingPathComponent("umbra-project-model.init.gradle")
        try GradleProjectModelScript.source.write(to: scriptURL, atomically: true, encoding: .utf8)
        let outputURL = workDirectory.appendingPathComponent("model.json")

        let result = try await runner.run(
            projectDirectory: projectDirectory,
            tasks: [":umbraProjectModel"],
            arguments: [
                "--init-script", scriptURL.path,
                "--no-configuration-cache",
                "-PumbraModelOutput=\(outputURL.path)"
            ],
            javaHome: javaHome,
            timeout: timeout
        )

        guard result.exitCode == 0 else {
            throw GradleProjectModelExtractionError.syncFailed(result)
        }
        guard let data = try? Data(contentsOf: outputURL) else {
            throw GradleProjectModelExtractionError.missingOutput(result)
        }
        do {
            let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: data)
            return (model, result)
        } catch {
            throw GradleProjectModelExtractionError.decodingFailed(underlying: String(describing: error), result: result)
        }
    }
}
