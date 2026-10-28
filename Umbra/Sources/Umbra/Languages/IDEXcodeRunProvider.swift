import Foundation
import JavaIntelligence
import SubprocessKit
import SwiftIntelligence

/// Run Tests and the gutter's test buttons for Swift files in an Xcode project.
///
/// A test run is `xcodebuild test -scheme <scheme> -only-testing …` with a result bundle, once the
/// folder is trusted (build phases can run scripts), and the bundle is read with `xcrun xcresulttool
/// get test-results tests` into the shape Test Results shows (`JavaTestRunResult`: a target is a
/// class's module, a file a class). The gutter shows the file's suites and tests from its syntax,
/// `⌃⇧R` runs the caret's. The passing run's bundle stays on
/// `lastResultBundle`, so Run with Coverage reads it with `xccov`. Coverage and profiling live in
/// `IDEXcodeRunProvider+Instrumentation`.
@MainActor
final class IDEXcodeRunProvider: IDERunProvider {
    let id = "xcode"
    let languageIdentifiers: Set<String> = ["swift"]
    let xcode: IDEXcodeProjectSystem
    weak var workspace: IDEWorkspace?

    /// The Swift menu's explicit choice; else `scheme()` picks the test target's scheme.
    var selectedScheme: String?
    /// The passing run's result bundle, kept for the coverage step. Cleared when a new run starts.
    private(set) var lastResultBundle: URL?
    /// Sortable run IDs double as bundle names, so pruning keeps the newest ten.
    static func runID(date: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(UUID().uuidString.prefix(8))"
    }

    private var lastTest: TestRun?
    /// The test target that ran each class, from the result bundle's `Target` nodes. Rerun Failed
    /// needs it: `-only-testing` starts at the target, and a scheme can test several.
    private var lastTargets: [String: String] = [:]

    private struct TestRun {
        var title: String
        var filters: [String]
        var coverage: Bool
    }

    init(xcode: IDEXcodeProjectSystem, workspace: IDEWorkspace) {
        self.xcode = xcode
        self.workspace = workspace
    }

    // MARK: Schemes

    /// The project's schemes, through `xcodebuild -list -json`. Read-only: no trust prompt.
    func schemes() async -> [String] {
        guard let data = await listData() else { return [] }
        return XcodeTestCommand.schemes(from: data)
    }

    /// The raw `-list -json` output, for the fixture the `XCLIST_FIXTURES=1` test run refreshes.
    func listData() async -> Data? {
        guard let root = xcode.rootURL else { return nil }
        let environment = xcode.launchEnvironment
        guard let xcodebuild = IDEXcodeProjectSystem.resolveXcodebuild(environment: environment) else { return nil }
        var request = SubprocessRequest(executable: xcodebuild, arguments: ["-list", "-json"])
        request.workingDirectory = root
        request.environment = environment ?? ProcessInfo.processInfo.environment
        request.timeout = .seconds(60)
        do {
            let result = try await SubprocessRunner.run(request)
            return result.stdout.text.data(using: .utf8)
        } catch {
            return nil
        }
    }

    /// The scheme tests run with: the Swift menu's explicit choice, else the scheme named like a
    /// test target, else the first listed scheme.
    private func scheme() async -> String? {
        if let selectedScheme { return selectedScheme }
        let schemes = await schemes()
        let testTargets = Set(xcode.model?.targets.filter { $0.kind == .test }.map(\.name) ?? [])
        selectedScheme = schemes.first { testTargets.contains($0) } ?? schemes.first
        return selectedScheme
    }

    // MARK: Availability

    enum Context {
        case tests(target: String)
    }

    /// What Run does for a file: its test target's tests, or nothing (programs come later).
    func context(for url: URL?) -> Context? {
        guard let url, let model = xcode.model else { return nil }
        if let target = testTarget(for: url, in: model) { return .tests(target: target) }
        return nil
    }

    /// The test target compiling `url`, if any.
    func testTarget(for url: URL, in model: IDEXcodeProjectModel) -> String? {
        let path = url.standardizedFileURL.path
        let tests = Set(model.targets.filter { $0.kind == .test }.map(\.name))
        guard !tests.isEmpty else { return nil }
        let matching = model.sourceRoots.filter { root in
            root.isFolder ? path.hasPrefix(root.url.path + "/") : path == root.url.path
        }.sorted { $0.url.path.count > $1.url.path.count }
        for root in matching {
            for name in root.targets.sorted() where tests.contains(name) { return name }
        }
        return nil
    }

    func canRun(_ document: IDERunDocument) -> Bool {
        guard let language = document.languageIdentifier, languageIdentifiers.contains(language) else { return false }
        return context(for: document.url) != nil
    }

    func canDebug(fileURL: URL?) -> Bool { false }

    func runHelp(fileURL: URL?) -> String {
        switch context(for: fileURL) {
        case .tests: return "Run tests"
        case nil: return "Run (no test target holds this file)"
        }
    }

    func debugHelp(fileURL: URL?, canRun _: Bool) -> String {
        "Debugging is not available for Xcode tests"
    }

    // MARK: Runnable locations

    func runnableLocations(in document: IDERunDocument) async -> [IDERunnableLocation] {
        guard let workspace, let parsed = SwiftAnalysis.parse(document.text) else { return [] }
        var locations: [IDERunnableLocation] = []
        func line(of bytes: Range<Int>) -> Int { parsed.text.position(atByte: bytes.lowerBound).line + 1 }

        let xcTestCases = Set(await workspace.swiftSupport.index.descendants(of: "XCTestCase", visibleFrom: document.url).map(\.declaration.name))

        func visit(_ declarations: [SwiftFileModel.Declaration]) {
            for declaration in declarations {
                guard declaration.kind == .class || declaration.kind == .struct || declaration.kind == .actor
                    || declaration.kind == .enum else { continue }
                let isXCTest = declaration.inherits.contains("XCTestCase") || xcTestCases.contains(declaration.name)
                let isSuite = declaration.attributes.contains("Suite")
                var tests: [IDERunnableLocation] = []
                for member in declaration.members where member.kind == .function {
                    let isXCTestMethod = isXCTest && member.name.hasPrefix("test") && member.parameters.isEmpty
                    if isXCTestMethod || member.attributes.contains("Test") {
                        tests.append(IDERunnableLocation(kind: .test, line: line(of: member.nameBytes), title: "\(member.name)()"))
                    }
                }
                if isXCTest || isSuite || !tests.isEmpty {
                    locations.append(IDERunnableLocation(kind: .testGroup, line: line(of: declaration.nameBytes), title: declaration.name))
                    locations.append(contentsOf: tests)
                }
                visit(declaration.members)
            }
        }
        visit(parsed.model.declarations)
        // Free `@Test` functions.
        for declaration in parsed.model.declarations where declaration.kind == .function && declaration.attributes.contains("Test") {
            locations.append(IDERunnableLocation(kind: .test, line: line(of: declaration.nameBytes), title: "\(declaration.name)()"))
        }
        return locations.sorted { $0.line < $1.line }
    }

    // MARK: Running

    func run(_ document: IDERunDocument, mode: IDERunMode) {
        guard workspace != nil else { return }
        switch context(for: document.url) {
        case .tests(let target)?:
            guard mode == .run else { return }
            runTests(title: target, filters: [target])
        case nil: break
        }
    }

    func run(_ document: IDERunDocument, location: IDERunnableLocation, mode: IDERunMode) {
        guard workspace != nil else { return }
        switch location.kind {
        case .test, .testGroup:
            guard mode == .run else { return }
            let filter = testFilter(for: location, in: document)
            runTests(title: location.title, filters: [filter])
        case .entryPoint, .preview:
            break
        }
    }

    func runInContext(_ document: IDERunDocument, mode: IDERunMode) async -> Bool {
        guard workspace != nil else { return false }
        let locations = await runnableLocations(in: document)
        guard let parsed = SwiftAnalysis.parse(document.text) else { return false }
        let caretLine = parsed.text.position(utf16: document.caretUTF16Offset).line + 1
        if let location = locations.last(where: { $0.line <= caretLine }) {
            run(document, location: location, mode: mode)
            return true
        }
        return false
    }

    func rerun(_ session: IDERunSession) {
        guard workspace != nil, let last = lastTest else { return }
        runTests(title: last.title, filters: last.filters)
    }

    var hasActiveWork: Bool { xcode.isRunningTasks }

    func stop() {
        xcode.cancelTasks()
    }

    func projectTasksDidFinish(_ report: IDEProjectTaskReport) {}

    // MARK: Tests

    /// `Target/Class/method` for a method, `Target/Class` for a class, from the document's test target.
    func testFilter(for location: IDERunnableLocation, in document: IDERunDocument) -> String {
        guard let parsed = SwiftAnalysis.parse(document.text),
              let url = document.url, let model = xcode.model,
              let target = testTarget(for: url, in: model) else { return location.title }
        let bareName = location.title.replacingOccurrences(of: "()", with: "")
        func find(_ declarations: [SwiftFileModel.Declaration], owner: String?) -> String? {
            for declaration in declarations {
                let line = parsed.text.position(atByte: declaration.nameBytes.lowerBound).line + 1
                if line == location.line {
                    if location.kind == .testGroup { return target + "/" + declaration.name }
                    if let owner { return target + "/" + owner + "/" + bareName }
                    return target + "/" + bareName
                }
                if declaration.kind.isNominalType, let found = find(declaration.members, owner: declaration.name) {
                    return found
                }
            }
            return nil
        }
        return find(parsed.model.declarations, owner: nil) ?? location.title
    }

    /// The cache every Xcode run of a project shares: DerivedData, result bundles, and
    /// (for Profile) the Release build. `Caches/com.umbra.editor/Xcode/<hash of project path>/`,
    /// as the plan fixed it; nothing is written into the project.
    static func cacheFolder(for root: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let key = String(format: "%08x", abs(root.standardizedFileURL.path.hashValue) & 0xffff_ffff)
        return caches.appendingPathComponent("com.umbra.editor/Xcode/\(key)", isDirectory: true)
    }

    /// Keeps the newest ten result bundles of the cache.
    static func pruneBundles(in cache: URL) {
        let bundles = ((try? FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "xcresult" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in bundles.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
    }

    /// Runs the scheme's tests (or just `filters`) and reports them in Test Results.
    func runTests(title: String, filters: [String], coverage: Bool = false) {
        lastTest = TestRun(title: title, filters: filters, coverage: coverage)
        startRun(title: title, filters: filters, coverage: coverage)
    }

    /// The run itself. Rerun goes through here so Rerun Failed never replaces the explicit run
    /// that Rerun repeats.
    private func startRun(title: String, filters: [String], coverage: Bool) {
        guard let workspace, let root = xcode.rootURL, let project = xcode.model?.projectURL else { return }
        if xcode.isRunningTasks {
            workspace.reportRunProblem("Xcode is busy; wait for it or stop it first.")
            return
        }
        lastResultBundle = nil
        let cache = Self.cacheFolder(for: root)
        let derivedData = cache.appendingPathComponent("DerivedData", isDirectory: true)
        try? FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        let bundle = cache.appendingPathComponent("\(Self.runID()).xcresult")
        Task { [weak self] in
            guard let self, let workspace = self.workspace else { return }
            guard await self.xcode.ensureTrusted() else { return }
            guard let scheme = await self.scheme() else {
                workspace.reportRunProblem("This project has no scheme to test.")
                return
            }
            workspace.testResults.beginRun(label: "Running \(title)…", rerunHandler: { [weak self] failedOnly in
                self?.rerunTests(failedOnly: failedOnly)
            })
            workspace.showTestResults()
            let invocation = IDEXcodeInvocation(
                title: "xcodebuild test -scheme \(scheme)" + (coverage ? " -enableCodeCoverage YES" : "")
                    + " " + filters.joined(separator: " "),
                arguments: XcodeTestCommand.testArguments(
                    project: project, scheme: scheme, destination: "platform=macOS",
                    derivedDataPath: derivedData, resultBundlePath: bundle,
                    tests: filters, coverage: coverage)
            )
            self.xcode.run([invocation]) { [weak self] outcomes in
                guard let self, let workspace = self.workspace else { return }
                guard let outcome = outcomes.first else {
                    workspace.testResults.stopRun(message: "The tests did not run.")
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, let workspace = self.workspace else { return }
                    guard outcome.succeeded, FileManager.default.fileExists(atPath: bundle.path) else {
                        try? FileManager.default.removeItem(at: bundle)
                        let message: String
                        if outcome.cancelled {
                            message = "The test run was stopped."
                        } else if outcome.succeeded {
                            message = "xcodebuild reported success but wrote no result bundle."
                        } else {
                            message = "xcodebuild failed; see the Xcode console."
                        }
                        workspace.testResults.stopRun(message: message)
                        return
                    }
                    self.lastResultBundle = bundle
                    Self.pruneBundles(in: cache)
                    await self.finishRun(bundle: bundle)
                    if coverage, !outcome.cancelled { self.collectCoverage(label: title) }
                    workspace.showTestResults()
                }
            }
        }
    }

    private func finishRun(bundle: URL) async {
        guard let workspace else { return }
        guard let output = await testResults(bundle: bundle) else {
            workspace.testResults.stopRun(message: "xcresulttool did not answer; see the Xcode console.")
            return
        }
        let classes = await workspace.swiftSupport.index.allTypeDeclarations()
        var files: [String: URL] = [:]
        for ref in classes where files[ref.declaration.name] == nil { files[ref.declaration.name] = ref.url }
        let cases: [JavaTestCaseResult] = output.map { run in
            JavaTestCaseResult(
                className: run.className, name: run.name,
                status: run.status == .passed ? .passed : run.status == .skipped ? .skipped : .failed,
                duration: run.duration, message: run.message,
                sourceFile: files[run.className], line: nil
            )
        }
        lastTargets = Dictionary(output.map { ($0.className, $0.target) }, uniquingKeysWith: { first, _ in first })
        let parsed = JavaTestRunResult(cases: cases.sorted {
            if $0.className == $1.className { return $0.name < $1.name }
            return $0.className < $1.className
        })
        if parsed.cases.isEmpty {
            workspace.testResults.stopRun(message: "No tests were found.")
        } else {
            workspace.testResults.finishRun(parsed)
        }
    }

    /// The raw `xcrun xcresulttool get test-results tests` JSON for the bundle. Off the main
    /// actor's path: the caller awaits it from a task.
    func testResultData(bundle: URL) async -> Data? {
        let environment = xcode.launchEnvironment
        guard let xcrun = Self.resolveXcrun(environment: environment) else { return nil }
        var request = SubprocessRequest(
            executable: xcrun,
            arguments: XcodeTestCommand.testResultArguments(resultBundlePath: bundle)
        )
        request.workingDirectory = xcode.rootURL ?? bundle.deletingLastPathComponent()
        request.environment = environment ?? ProcessInfo.processInfo.environment
        request.timeout = .seconds(120)
        do {
            let result = try await SubprocessRunner.run(request)
            return result.stdout.text.data(using: .utf8)
        } catch {
            return nil
        }
    }

    /// `xcrun xcresulttool get test-results tests` for the bundle, parsed. Off the main actor's
    /// path: the caller awaits it from a task.
    func testResults(bundle: URL) async -> [XcodeTestCommand.TestRun]? {
        guard let data = await testResultData(bundle: bundle) else { return nil }
        return try? XcodeTestCommand.runResults(from: data)
    }

    /// `xcrun` on PATH (the tests install a fake one there), else the toolchain's.
    static func resolveXcrun(environment: [String: String]?) -> String? {
        let path = environment?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("xcrun").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        if environment == nil, FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") { return "/usr/bin/xcrun" }
        return nil
    }

    /// Rerun from the Test Results tab: the last run, or just what failed.
    private func rerunTests(failedOnly: Bool) {
        guard let workspace, let last = lastTest else { return }
        guard failedOnly else {
            startRun(title: last.title, filters: last.filters, coverage: last.coverage)
            return
        }
        var filters: [String] = []
        for testCase in workspace.testResults.cases where testCase.status == .failed || testCase.status == .aborted {
            let method = testCase.name.replacingOccurrences(of: "()", with: "")
            if let target = lastTargets[testCase.className], !target.isEmpty {
                filters.append(XcodeTestCommand.onlyTesting(target: target, class: testCase.className, method: method))
            } else {
                filters.append("\(testCase.className)/\(method)")
            }
        }
        guard !filters.isEmpty else { return }
        let unique = Array(NSOrderedSet(array: filters)) as? [String] ?? filters
        startRun(
            title: unique.count == 1 ? unique[0] : "\(unique.count) failed tests",
            filters: unique, coverage: last.coverage
        )
    }
}
