import Foundation

/// What to run when the user asks to execute tests.
public enum JavaTestRunScope: Sendable, Equatable {
    case allInModule(gradleTaskPath: String)
    case testClass(JavaTestClass)
    case testMethod(JavaTestMethod, taskPath: String)
}

/// Parameters for a Gradle-backed test invocation.
public struct JavaTestRunRequest: Sendable, Equatable {
    public let gradleTaskPath: String
    public let testFilter: String?
    public let projectRoot: URL
    /// Directories where Surefire/JUnit Platform XML reports are written for this task.
    public let reportDirectories: [URL]

    public init(
        gradleTaskPath: String,
        testFilter: String?,
        projectRoot: URL,
        reportDirectories: [URL]
    ) {
        self.gradleTaskPath = gradleTaskPath
        self.testFilter = testFilter
        self.projectRoot = projectRoot
        self.reportDirectories = reportDirectories
    }
}

/// Builds Gradle task invocations and locates test report directories.
public enum JavaTestRunner {
    public static func request(
        scope: JavaTestRunScope,
        projectRoot: URL,
        model: JavaGradleProjectModel?
    ) -> JavaTestRunRequest? {
        switch scope {
        case .allInModule(let taskPath):
            return JavaTestRunRequest(
                gradleTaskPath: taskPath,
                testFilter: nil,
                projectRoot: projectRoot,
                reportDirectories: reportDirectories(forTaskPath: taskPath, model: model)
            )
        case .testClass(let testClass):
            return JavaTestRunRequest(
                gradleTaskPath: testClass.gradleTaskPath,
                testFilter: testClass.qualifiedName,
                projectRoot: projectRoot,
                reportDirectories: reportDirectories(forTaskPath: testClass.gradleTaskPath, model: model)
            )
        case .testMethod(let method, let taskPath):
            return JavaTestRunRequest(
                gradleTaskPath: taskPath,
                testFilter: method.gradleTestFilter(includeMethod: true),
                projectRoot: projectRoot,
                reportDirectories: reportDirectories(forTaskPath: taskPath, model: model)
            )
        }
    }

    /// Gradle CLI arguments after `--console=plain` and before the task path.
    public static func gradleArguments(for request: JavaTestRunRequest, continueOnFailure: Bool = true) -> [String] {
        var args = ["--no-configuration-cache"]
        if continueOnFailure { args.append("--continue") }
        if let filter = request.testFilter {
            args.append(contentsOf: ["--tests", filter])
        }
        return args
    }

    public static func isTestTask(_ taskPath: String) -> Bool {
        guard let last = taskPath.split(separator: ":").last.map(String.init) else { return false }
        return last == "test" || last.hasSuffix("Test")
    }

    private static func reportDirectories(forTaskPath taskPath: String, model: JavaGradleProjectModel?) -> [URL] {
        guard let model else { return [] }
        let components = taskPath.split(separator: ":").map(String.init)
        guard let taskName = components.last else { return [] }
        let projectPath = components.count > 1 ? ":" + components.dropLast().joined(separator: ":") : ":"
        guard let subproject = model.subprojects.first(where: { $0.path == projectPath }) else { return [] }
        guard let sourceSet = subproject.sourceSets.first(where: { $0.name == taskName }) else { return [] }
        var dirs: [URL] = []
        for output in sourceSet.outputDirs {
            let parent = output.deletingLastPathComponent().deletingLastPathComponent()
            dirs.append(parent.appendingPathComponent("test-results/\(taskName)", isDirectory: true))
        }
        if dirs.isEmpty, let directory = subproject.directory as URL? {
            dirs.append(directory.appendingPathComponent("build/test-results/\(taskName)", isDirectory: true))
        }
        return dirs
    }
}
