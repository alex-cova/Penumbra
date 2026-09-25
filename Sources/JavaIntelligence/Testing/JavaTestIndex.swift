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

    /// Scans every `.java` file under `directories`.
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
        let discovered = JavaTestDiscovery.discover(source: source, url: key)
        let methods = discovered.values.flatMap { $0 }.sorted { $0.line < $1.line }
        guard !methods.isEmpty else {
            classesByFile[key] = nil
            return
        }
        let className = methods.map(\.className).sorted().last ?? methods[0].className
        let context = gradleContext(for: key)
        classesByFile[key] = JavaTestClass(
            qualifiedName: className,
            sourceFile: key,
            methods: methods,
            gradleProjectPath: context.projectPath,
            gradleTaskPath: context.taskPath
        )
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
            guard url.pathExtension == "java" else { continue }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let discovered = JavaTestDiscovery.discover(source: source, url: url.standardizedFileURL)
            let allMethods = discovered.values.flatMap { $0 }.sorted { $0.line < $1.line }
            guard !allMethods.isEmpty else { continue }
            let className = allMethods.first!.className
            let context = gradleContext(for: url)
            result[url.standardizedFileURL] = JavaTestClass(
                qualifiedName: className,
                sourceFile: url.standardizedFileURL,
                methods: allMethods,
                gradleProjectPath: context.projectPath,
                gradleTaskPath: context.taskPath
            )
        }
    }

    private static func testSourceRootPaths(from model: JavaGradleProjectModel) -> Set<String> {
        Set(model.existingTestSourceDirectories.map(\.standardizedFileURL.path))
    }
}
