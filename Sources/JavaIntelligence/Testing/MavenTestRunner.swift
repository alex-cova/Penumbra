import Foundation

/// The Maven invocation for one test scope, and where Surefire writes its XML.
public struct MavenTestCommand: Sendable, Equatable {
    /// `group:artifact` for `-pl`, or empty when the whole reactor runs.
    public var selector: String
    public var goals: [String]
    public var arguments: [String]
    public var reportDirectories: [URL]

    public init(selector: String, goals: [String], arguments: [String], reportDirectories: [URL]) {
        self.selector = selector
        self.goals = goals
        self.arguments = arguments
        self.reportDirectories = reportDirectories
    }
}

/// Builds `-pl <g:a> -am test -Dtest=<Class[#m1+m2],…> -Dsurefire.failIfNoSpecifiedTests=false`.
/// A debug run adds Surefire's JDWP agent on ``JavaLaunchCommand/gradleDebugJdwpPort``.
public enum MavenTestRunner {
    /// Suspends the test JVM until a debugger connects, on the same port Gradle's `--debug-jvm` uses.
    public static let debugArgument =
        "-Dmaven.surefire.debug=-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:\(JavaLaunchCommand.gradleDebugJdwpPort)"

    public static func command(
        scope: JavaTestRunScope,
        model: MavenProjectModel,
        debug: Bool = false
    ) -> MavenTestCommand? {
        let taskPath = primaryTaskPath(scope)
        let wholeReactor = taskPath == "test"
        let modulePath = modulePath(forTask: taskPath)
        let modules = wholeReactor ? model.modules : model.modules.filter { $0.path == modulePath }
        guard !modules.isEmpty else { return nil }
        var arguments: [String] = []
        if !wholeReactor, let module = modules.first {
            arguments += ["-pl", module.selector, "-am"]
        }
        arguments.append("-Dsurefire.failIfNoSpecifiedTests=false")
        if let pattern = testPattern(scope), !pattern.isEmpty {
            arguments.append("-Dtest=\(pattern)")
        }
        if debug { arguments.append(debugArgument) }
        let selector = wholeReactor ? "" : (modules.first?.selector ?? "")
        return MavenTestCommand(
            selector: selector,
            goals: ["test"],
            arguments: arguments,
            reportDirectories: modules.map { $0.directory.appendingPathComponent("target/surefire-reports", isDirectory: true) }
        )
    }

    /// Surefire's `-Dtest` value for the scope, or `nil` when every test in the module runs.
    public static func testPattern(_ scope: JavaTestRunScope) -> String? {
        switch scope {
        case .allInModule:
            return nil
        case .testClass(let testClass):
            return testClass.qualifiedName
        case .testMethod(let method, _):
            return "\(method.className)#\(method.methodName)"
        case .tests(_, let filters):
            return pattern(filters)
        }
    }

    private static func primaryTaskPath(_ scope: JavaTestRunScope) -> String {
        switch scope {
        case .allInModule(let taskPath): return taskPath
        case .testClass(let testClass): return testClass.gradleTaskPath
        case .testMethod(_, let taskPath): return taskPath
        case .tests(let taskPath, _): return taskPath
        }
    }

    /// `:services:api:test` is the module `:services:api`. `:test` is the root. An unqualified
    /// `test` is the whole reactor.
    private static func modulePath(forTask taskPath: String) -> String {
        if taskPath == "test" { return "test" }
        if taskPath == ":test" { return ":" }
        if taskPath.hasSuffix(":test") {
            let head = String(taskPath.dropLast(":test".count))
            return head.isEmpty ? ":" : head
        }
        return taskPath
    }

    /// Groups Gradle-shaped filters (`com.example.Foo.bar`) into `com.example.Foo#bar`.
    private static func pattern(_ filters: [String]) -> String? {
        var order: [String] = []
        var methods: [String: [String]] = [:]
        for filter in filters where !filter.isEmpty {
            let piece = split(filter)
            if methods[piece.className] == nil { order.append(piece.className) }
            if let method = piece.method, !methods[piece.className, default: []].contains(method) {
                methods[piece.className, default: []].append(method)
            }
        }
        guard !order.isEmpty else { return nil }
        return order.map { name in
            let selected = methods[name] ?? []
            return selected.isEmpty ? name : "\(name)#\(selected.joined(separator: "+"))"
        }.joined(separator: ",")
    }

    private static func split(_ filter: String) -> (className: String, method: String?) {
        if let hash = filter.firstIndex(of: "#") {
            let method = String(filter[filter.index(after: hash)...])
            return (String(filter[..<hash]), method.isEmpty ? nil : method)
        }
        let parts = filter.split(separator: ".").map(String.init)
        if parts.count >= 2, let last = parts.last, let first = last.first, first.isLowercase {
            return (parts.dropLast().joined(separator: "."), last)
        }
        return (filter, nil)
    }
}
