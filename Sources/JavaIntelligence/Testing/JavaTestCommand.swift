import Foundation

/// What to run.
public enum JavaTestRunRequest: Sendable, Hashable {
    /// One re-run target: a class, optionally narrowed to a method, on a Test task.
    public struct Filter: Sendable, Hashable {
        /// Binary name, e.g. `pkg.Outer$Inner`.
        public let className: String
        /// Base method name (no parameter list or invocation suffix); `nil` for the whole class.
        public let methodName: String?
        public let taskPath: String

        public init(className: String, methodName: String? = nil, taskPath: String) {
            self.className = className
            self.methodName = methodName
            self.taskPath = taskPath
        }
    }

    /// Every Test task of the Gradle project at this path (`:app`, `:` for the root).
    case allInSubproject(String)
    /// A whole Test task, e.g. `:app:test` or `:app:integrationTest`.
    case sourceSetTask(String)
    case `class`(binaryName: String, taskPath: String)
    case method(binaryName: String, methodName: String, taskPath: String)
    case failed([Filter])
}

/// Builds the Gradle invocation for a ``JavaTestRunRequest``.
///
/// Encoding (matches `GradleCommandRunner.run`, which launches
/// `gradle --console=plain <arguments> <tasks>`):
/// - `tasks` is the ordered task list *including the `--tests` options*, because Gradle binds
///   `--tests` to the task directly before it:
///   `[":app:cleanTest", ":app:test", "--tests", "pkg.A", "--tests", "pkg.B.m"]`. The clean task
///   comes first so an up-to-date test task still reruns.
/// - `arguments` holds the global options: `["-I", "<script path>"]`.
///
/// Pass both straight to `runGradleTasks(_:arguments:)`. No shell is involved (the runner spawns the
/// process directly), so class and method names need no quoting; `$` in a nested class name is
/// kept as Gradle expects it (`pkg.Outer$Inner`). A parameterized or dynamic test is filtered by
/// its base method name only.
public enum JavaTestCommand {
    public static func make(
        request: JavaTestRunRequest,
        model: JavaGradleProjectModel?,
        initScriptURL: URL
    ) -> (tasks: [String], arguments: [String]) {
        var tasks: [String] = []
        // Filters grouped per task, in first-seen order.
        var order: [String] = []
        var filters: [String: [String]] = [:]

        func addTask(_ path: String) {
            if filters[path] == nil {
                order.append(path)
                filters[path] = []
            }
        }
        func addFilter(_ path: String, _ pattern: String) {
            addTask(path)
            if filters[path]?.contains(pattern) == false { filters[path]?.append(pattern) }
        }

        switch request {
        case .allInSubproject(let projectPath):
            for path in testTaskPaths(inProject: projectPath, model: model) { addTask(path) }
        case .sourceSetTask(let path):
            addTask(path)
        case .class(let name, let path):
            addFilter(path, name)
        case .method(let name, let method, let path):
            addFilter(path, "\(name).\(method)")
        case .failed(let list):
            for f in list {
                if let method = f.methodName, !method.isEmpty {
                    addFilter(f.taskPath, "\(f.className).\(method)")
                } else {
                    addFilter(f.taskPath, f.className)
                }
            }
        }

        for path in order {
            tasks.append(cleanTaskPath(forTestTask: path))
            tasks.append(path)
            for pattern in filters[path] ?? [] {
                tasks.append("--tests")
                tasks.append(pattern)
            }
        }
        return (tasks, ["-I", initScriptURL.path])
    }

    /// The Test task that runs tests of `file`: the project's task registered for the containing
    /// source set (`test` for the `test` source set), else `<project>:test`. `nil` outside the model.
    public static func testTaskPath(forFile file: URL, model: JavaGradleProjectModel) -> String? {
        guard let (subproject, sourceSet) = model.sourceSet(containing: file) else { return nil }
        if let task = subproject.testTasks.first(where: { $0.sourceSetName == sourceSet.name }) {
            return task.path
        }
        if sourceSet.name == "test" {
            return taskPath(project: subproject.path, name: "test")
        }
        return subproject.testTasks.first?.path ?? taskPath(project: subproject.path, name: "test")
    }

    /// Every Test task path of a project, falling back to `<project>:test`.
    static func testTaskPaths(inProject projectPath: String, model: JavaGradleProjectModel?) -> [String] {
        if let subproject = model?.subprojects.first(where: { $0.path == projectPath }), !subproject.testTasks.isEmpty {
            return subproject.testTasks.map(\.path)
        }
        return [taskPath(project: projectPath, name: "test")]
    }

    /// `:app:test` -> `:app:cleanTest`; `:integrationTest` -> `:cleanIntegrationTest`.
    static func cleanTaskPath(forTestTask path: String) -> String {
        let (prefix, name) = split(path)
        guard let first = name.first else { return path }
        return prefix + "clean" + first.uppercased() + name.dropFirst()
    }

    static func taskPath(project: String, name: String) -> String {
        project == ":" || project.isEmpty ? ":\(name)" : "\(project):\(name)"
    }

    /// Splits `:a:b:test` into (`:a:b:`, `test`).
    private static func split(_ path: String) -> (String, String) {
        guard let colon = path.lastIndex(of: ":") else { return ("", path) }
        return (String(path[...colon]), String(path[path.index(after: colon)...]))
    }
}
