import Foundation

/// In-memory index of discovered JUnit tests under the project's test source roots.
public actor JavaTestIndex {
    private var classesByFile: [URL: JavaTestClass] = [:]
    private var testSourceRootPaths: Set<String> = []
    private var gradleModel: JavaGradleProjectModel?
    private var debounceTasks: [URL: Task<Void, Never>] = [:]
    private let debounceNanoseconds: UInt64

    public init(debounceMilliseconds: UInt64 = 300) {
        debounceNanoseconds = debounceMilliseconds * 1_000_000
    }

    public func setGradleModel(_ model: JavaGradleProjectModel?) {
        gradleModel = model
        testSourceRootPaths = model.map(Self.testSourceRootPaths(from:)) ?? []
    }

    /// Scans Java and Kotlin test declarations under `directories`.
    public func reindexAll(in directories: [URL]) {
        var next: [URL: JavaTestClass] = [:]
        for directory in directories {
            scanDirectory(directory, into: &next)
        }
        classesByFile = next
    }

    public func scheduleRescan(file: URL, source: String) {
        let key = file.standardizedFileURL
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [debounceNanoseconds] in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self.rescan(file: key, source: source)
        }
    }

    public func rescan(file: URL, source: String) {
        let key = file.standardizedFileURL
        guard isTestSource(file: key) else {
            classesByFile[key] = nil
            return
        }
        classesByFile[key] = discover(file: key, source: source)
    }

    public func testClass(for file: URL) -> JavaTestClass? {
        classesByFile[file.standardizedFileURL]
    }

    public func allTestClasses() -> [JavaTestClass] {
        Array(classesByFile.values).sorted { $0.sourceFile.path < $1.sourceFile.path }
    }

    public func isTestSource(file: URL) -> Bool {
        let path = file.standardizedFileURL.path
        if testSourceRootPaths.contains(where: { path.hasPrefix($0 + "/") || path == $0 }) { return true }
        return path.contains("/src/test/") || path.contains("/src/testFixtures/")
    }

    private func gradleContext(for file: URL) -> (projectPath: String, taskPath: String) {
        if let model = gradleModel, let match = model.sourceSet(containing: file) {
            let taskPath = model.gradleTaskPath(subproject: match.subproject, sourceSet: match.sourceSet)
            return (match.subproject.path, taskPath)
        }
        return (":", ":test")
    }

    private func scanDirectory(_ directory: URL, into result: inout [URL: JavaTestClass]) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            guard ["java", "kt"].contains(url.pathExtension),
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let key = url.standardizedFileURL
            result[key] = discover(file: key, source: source)
        }
    }

    private func discover(file: URL, source: String) -> JavaTestClass? {
        let discovered: [String: [JavaTestMethod]]
        switch file.pathExtension {
        case "java":
            discovered = JavaTestDiscovery.discover(source: source, url: file)
        case "kt":
            guard let model = gradleModel, let match = model.sourceSet(containing: file),
                  match.sourceSet.name == "test" || match.subproject.testTasks.contains(where: { $0.sourceSetName == match.sourceSet.name }) else { return nil }
            discovered = KotlinJVMTestDiscovery.discover(source: source, url: file)
        default:
            return nil
        }
        let methods = discovered.values.flatMap { $0 }.sorted { $0.line < $1.line }
        guard let first = methods.first else { return nil }
        let context = gradleContext(for: file)
        return JavaTestClass(qualifiedName: first.className, sourceFile: file, methods: methods,
                             gradleProjectPath: context.projectPath, gradleTaskPath: context.taskPath)
    }

    private static func testSourceRootPaths(from model: JavaGradleProjectModel) -> Set<String> {
        Set(model.existingTestSourceDirectories.map(\.standardizedFileURL.path))
    }
}
