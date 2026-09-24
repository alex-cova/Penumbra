import Foundation

/// One runnable `@Test` (or JUnit 4 equivalent) method in a source file.
public struct JavaTestMethod: Sendable, Equatable, Identifiable {
    public let className: String
    public let methodName: String
    public let displayName: String
    public let sourceFile: URL
    /// 1-based line of the method name token.
    public let line: Int
    /// 0-based UTF-16 column of the method name token.
    public let column: Int
    public let framework: JavaTestFramework

    public init(
        className: String,
        methodName: String,
        displayName: String,
        sourceFile: URL,
        line: Int,
        column: Int,
        framework: JavaTestFramework
    ) {
        self.className = className
        self.methodName = methodName
        self.displayName = displayName
        self.sourceFile = sourceFile
        self.line = line
        self.column = column
        self.framework = framework
    }

    public var id: String { "\(className)#\(methodName)" }

    /// Gradle `--tests` filter for this method or its class.
    public func gradleTestFilter(includeMethod: Bool) -> String {
        includeMethod ? "\(className).\(methodName)" : className
    }
}
