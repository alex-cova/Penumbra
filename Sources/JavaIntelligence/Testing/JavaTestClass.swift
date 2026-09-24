import Foundation

/// Every discovered test method in one `.java` file, with the Gradle task that runs them.
public struct JavaTestClass: Sendable, Equatable, Identifiable {
    public let qualifiedName: String
    public let sourceFile: URL
    public let methods: [JavaTestMethod]
    /// Gradle project path, e.g. `:` or `:app`.
    public let gradleProjectPath: String
    /// Gradle verification task, e.g. `:test` or `:app:test`.
    public let gradleTaskPath: String

    public init(
        qualifiedName: String,
        sourceFile: URL,
        methods: [JavaTestMethod],
        gradleProjectPath: String,
        gradleTaskPath: String
    ) {
        self.qualifiedName = qualifiedName
        self.sourceFile = sourceFile
        self.methods = methods
        self.gradleProjectPath = gradleProjectPath
        self.gradleTaskPath = gradleTaskPath
    }

    public var id: URL { sourceFile.standardizedFileURL }
}
