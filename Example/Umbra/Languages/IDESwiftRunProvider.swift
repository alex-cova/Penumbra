import Foundation
import JavaIntelligence

/// Run, Run in Context and the gutter's play buttons for Swift files in a SwiftPM package.
///
/// A program is built through the project system first, so the compiler's problems reach Problems
/// and the SwiftPM console, and then started with `swift run --skip-build` as a Run-tab session
/// (interactive input, Stop, Rerun). Tests run as `swift test --filter …` with an xunit file the
/// Java report parser reads, so they land in Test Results. Debugging is not available.
@MainActor
final class IDESwiftRunProvider: IDERunProvider {
    let id = "swiftpm"
    let languageIdentifiers: Set<String> = ["swift"]
    let swiftPM: IDESwiftPMProjectSystem
    weak var workspace: IDEWorkspace?

    /// One identity per program, so a rerun takes over the tab of the last run of it.
    private var configurationIDs: [String: UUID] = [:]
    private var lastTest: TestRun?

    private struct TestRun {
        var title: String
        var filters: [String]
    }

    init(swiftPM: IDESwiftPMProjectSystem, workspace: IDEWorkspace) {
        self.swiftPM = swiftPM
        self.workspace = workspace
    }

    // MARK: Availability

    private enum Context {
        case executable(String)
        case tests(target: String)
    }

    /// What Run does for a file: its target's program, the package's only program, or its tests.
    private func context(for url: URL?) -> Context? {
        guard swiftPM.isActive, let manifest = swiftPM.manifest, let root = swiftPM.rootURL else { return nil }
        if let url, let module = manifest.moduleResolver(root: root)(url), let target = manifest.target(named: module) {
            switch target.kind {
            case .test:
                return .tests(target: target.name)
            case .executable:
                return .executable(target.name)
            default:
                break
            }
        }
        // A library's file runs the package's program when there is exactly one.
        let executables = manifest.executableNames
        if executables.count == 1, let name = executables.first { return .executable(name) }
        if let first = executables.first, url == nil { return .executable(first) }
        return nil
    }

    func canRun(_ document: IDERunDocument) -> Bool {
        guard let language = document.languageIdentifier, languageIdentifiers.contains(language) else { return false }
        return context(for: document.url) != nil
    }

    func canDebug(fileURL _: URL?) -> Bool { false }

    func runHelp(fileURL: URL?) -> String {
        switch context(for: fileURL) {
        case .executable(let name)?: return "Run \(name)"
        case .tests(let target)?: return "Run tests of \(target)"
        case nil: return "Run (no executable target in this package)"
        }
    }

    func debugHelp(fileURL _: URL?, canRun _: Bool) -> String {
        "Debugging is not available for Swift"
    }

    // MARK: Runnable locations

    func runnableLocations(in document: IDERunDocument) async -> [IDERunnableLocation] {
        guard let workspace, let parsed = SwiftAnalysis.parse(document.text) else { return [] }
        var locations: [IDERunnableLocation] = []
        func line(of bytes: Range<Int>) -> Int { parsed.text.position(atByte: bytes.lowerBound).line + 1 }

        if document.url?.lastPathComponent == "main.swift", context(for: document.url).map({
            if case .executable = $0 { return true }
            return false
        }) == true {
            locations.append(IDERunnableLocation(kind: .entryPoint, line: 1, title: "main"))
        }
        let xcTestCases = Set(await workspace.swiftSupport.index.descendants(of: "XCTestCase", visibleFrom: document.url).map(\.declaration.name))

        func visit(_ declarations: [SwiftFileModel.Declaration]) {
            for declaration in declarations {
                guard declaration.kind == .class || declaration.kind == .struct || declaration.kind == .actor
                    || declaration.kind == .enum else { continue }
                if declaration.attributes.contains("main") {
                    locations.append(IDERunnableLocation(kind: .entryPoint, line: line(of: declaration.nameBytes), title: "\(declaration.name).main()"))
                }
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
        guard mode == .run, workspace != nil else { return }
        switch context(for: document.url) {
        case .executable(let name)?: runExecutable(name)
        case .tests(let target)?: runTests(title: target, filters: ["\(target)."])
        case nil: break
        }
    }

    func run(_ document: IDERunDocument, location: IDERunnableLocation, mode: IDERunMode) {
        guard mode == .run, workspace != nil else { return }
        switch location.kind {
        case .entryPoint:
            if case .executable(let name)? = context(for: document.url) { runExecutable(name) }
        case .test, .testGroup:
            let filter = testFilter(for: location, in: document)
            runTests(title: location.title, filters: [filter])
        }
    }

    func runInContext(_ document: IDERunDocument, mode: IDERunMode) async -> Bool {
        guard mode == .run, workspace != nil else { return false }
        let locations = await runnableLocations(in: document)
        guard let parsed = SwiftAnalysis.parse(document.text) else { return false }
        let caretLine = parsed.text.position(utf16: document.caretUTF16Offset).line + 1
        // The nearest place at or above the caret: a test method inside a class beats the class.
        if let location = locations.last(where: { $0.line <= caretLine }) {
            run(document, location: location, mode: mode)
            return true
        }
        return false
    }

    func rerun(_ session: IDERunSession) {
        guard workspace != nil, let name = session.payload as? String else { return }
        runExecutable(name)
    }

    var hasActiveWork: Bool { swiftPM.isRunningTasks }

    func stop() {
        swiftPM.cancelTasks()
    }

    // MARK: Programs

    private func runExecutable(_ name: String) {
        guard let workspace else { return }
        if swiftPM.isRunningTasks {
            workspace.reportRunProblem("SwiftPM is busy; wait for it or stop it first.")
            return
        }
        let build = IDESwiftPMInvocation(title: "swift build --product \(name)", arguments: ["build", "--product", name])
        swiftPM.run([build]) { [weak self] outcomes in
            guard let self, outcomes.first?.succeeded == true else { return }
            self.startSession(for: name)
        }
    }

    private func startSession(for name: String) {
        guard let workspace, let root = swiftPM.rootURL else { return }
        let key = root.path + "#" + name
        let configurationID = configurationIDs[key] ?? UUID()
        configurationIDs[key] = configurationID
        let environment = swiftPM.launchEnvironment
        _ = workspace.runs.start(IDERunRequest(
            id: configurationID, title: name, providerID: id, payload: name, allowsMultipleInstances: false,
            prepare: { session in
                guard let swift = IDESwiftPMProjectSystem.resolveSwift(environment: environment) else {
                    session.fail("No swift found on PATH.")
                    return
                }
                session.start(IDEProcessLaunch(
                    executable: URL(fileURLWithPath: swift),
                    arguments: ["run", "--skip-build", name],
                    workingDirectory: root,
                    environment: environment ?? ProcessInfo.processInfo.environment,
                    displayCommand: "swift run --skip-build \(name)"
                ))
            }
        ))
        workspace.showRunTab()
    }

    // MARK: Tests

    /// `Module.Class/method` for a method, `Module.Class` for a class, from the document's text.
    private func testFilter(for location: IDERunnableLocation, in document: IDERunDocument) -> String {
        guard let parsed = SwiftAnalysis.parse(document.text), let manifest = swiftPM.manifest, let root = swiftPM.rootURL
        else { return location.title }
        let module = document.url.flatMap { manifest.moduleResolver(root: root)($0) }
        let prefix = module.map { "\($0)." } ?? ""
        let bareName = location.title.replacingOccurrences(of: "()", with: "")
        func find(_ declarations: [SwiftFileModel.Declaration], owner: String?) -> String? {
            for declaration in declarations {
                let line = parsed.text.position(atByte: declaration.nameBytes.lowerBound).line + 1
                if line == location.line {
                    if location.kind == .testGroup { return prefix + declaration.name }
                    return owner.map { "\(prefix)\($0)/\(bareName)" } ?? "\(prefix)\(bareName)"
                }
                if declaration.kind.isNominalType, let found = find(declaration.members, owner: declaration.name) { return found }
            }
            return nil
        }
        return find(parsed.model.declarations, owner: nil) ?? location.title
    }

    private func runTests(title: String, filters: [String]) {
        guard let workspace else { return }
        if swiftPM.isRunningTasks {
            workspace.reportRunProblem("SwiftPM is busy; wait for it or stop it first.")
            return
        }
        lastTest = TestRun(title: title, filters: filters)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-swift-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var arguments = ["test"]
        for filter in filters { arguments += ["--filter", filter] }
        arguments += ["--xunit-output", directory.appendingPathComponent("TEST-swift.xml").path]
        workspace.testResults.beginRun(label: "Running \(title)…", rerunHandler: { [weak self] failedOnly in
            self?.rerunTests(failedOnly: failedOnly)
        })
        workspace.showTestResults()
        let invocation = IDESwiftPMInvocation(title: "swift test \(filters.joined(separator: " "))", arguments: arguments)
        swiftPM.run([invocation]) { [weak self] outcomes in
            guard let self, let workspace = self.workspace else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            guard let outcome = outcomes.first else {
                workspace.testResults.stopRun(message: "The tests did not run.")
                try? FileManager.default.removeItem(at: directory)
                return
            }
            // The report is read after the index lookup below, so the directory goes at the end.
            Task { @MainActor [weak self] in
                defer { try? FileManager.default.removeItem(at: directory) }
                guard let self, let workspace = self.workspace else { return }
                let root = self.swiftPM.rootURL ?? directory
                let classes = await workspace.swiftSupport.index.allTypeDeclarations()
                var files: [String: URL] = [:]
                for ref in classes where files[ref.declaration.name] == nil { files[ref.declaration.name] = ref.url }
                let parsed = JUnitXMLReportParser.parseReports(in: [directory], projectRoot: root) { className in
                    files[className.split(separator: ".").last.map(String.init) ?? className]
                }
                if parsed.cases.isEmpty {
                    let message = outcome.cancelled
                        ? "The test run was stopped."
                        : (outcome.status == 0 ? "No tests were found." : "swift test failed; see the SwiftPM console.")
                    workspace.testResults.stopRun(message: message)
                } else {
                    workspace.testResults.finishRun(parsed)
                }
                workspace.showTestResults()
            }
        }
    }

    /// Rerun from the Test Results tab: the last run, or just what failed.
    private func rerunTests(failedOnly: Bool) {
        guard let workspace, let last = lastTest else { return }
        guard failedOnly else {
            runTests(title: last.title, filters: last.filters)
            return
        }
        var filters: [String] = []
        for testCase in workspace.testResults.cases where testCase.status == .failed || testCase.status == .aborted {
            let method = testCase.name.replacingOccurrences(of: "()", with: "")
            filters.append("\(testCase.className)/\(method)")
        }
        guard !filters.isEmpty else { return }
        let unique = Array(NSOrderedSet(array: filters)) as? [String] ?? filters
        runTests(title: unique.count == 1 ? unique[0] : "\(unique.count) failed tests", filters: unique)
    }
}
