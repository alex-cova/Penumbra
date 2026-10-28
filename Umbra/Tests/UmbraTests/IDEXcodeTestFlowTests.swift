import Foundation
import JavaIntelligence
import SubprocessKit
import SwiftIntelligence
import XCTest
@testable import Umbra

/// `xcodebuild test` → `xcresulttool` → Test Results for Xcode projects.
///
/// Fake `xcodebuild`/`xcrun` binaries on PATH cover selection, failure, rerun, and trust without
/// Xcode. `testRealTemplateTestsPassWithTheRealToolchain` runs the generated app template with the
/// real toolchain when Xcode is installed (skipped otherwise), and `TEST_FIXTURES=1` refreshes
/// `Tests/PenumbraTests/Fixtures/XcodeTests/TestResults.json` from that run.
@MainActor
final class IDEXcodeTestFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private struct Fixture {
        var directory: URL
        var root: URL
        var workspace: IDEWorkspace
        var xcode: IDEXcodeProjectSystem
        var provider: IDEXcodeRunProvider
        var argumentLog: URL
        var appTarget: String
        var testTarget: String
        var testFile: URL
    }

    private func waitUntil(seconds: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func install(name: String, script: String, log: URL, in bin: URL) throws {
        let tool = bin.appendingPathComponent(name)
        try "#!/bin/sh\n\(script)\n".write(to: tool, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    }

    /// The generated app, trusted unless asked otherwise, with fake binaries answering `test`
    /// (logging every invocation, materializing the result bundle) and `-list`, and `xcrun`
    /// serving `xcresultJSON` plus, when given, the `xccov` archive and report.
    private func makeFixture(
        xcresultJSON: String,
        makeBundle: Bool = true,
        trusted: Bool = true,
        archiveJSON: String? = nil,
        reportJSON: String? = nil
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-xcode-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.xcode.macos-app"))
        let root = try IDEProjectWriter.create(
            template, options: IDENewProjectOptions(name: "FlowApp", parentDirectory: directory))
        let store = ProjectTrustStore(storeURL: directory.appendingPathComponent("flow-trust.json"))
        if trusted { store.setTrusted(true, for: root) }
        let xcode = IDEXcodeProjectSystem(status: IDEProjectStatus(), trustStore: store)
        xcode.projectDidChange(root: root)
        let model = try XCTUnwrap(xcode.model)
        let appTarget = try XCTUnwrap(model.targets.first { $0.kind == .application }?.name)
        let testTarget = try XCTUnwrap(model.targets.first { $0.kind == .test }?.name)

        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("args.log")
        let bundleLine = makeBundle
            ? "if [ \"$prev\" = \"-resultBundlePath\" ]; then mkdir -p \"$a\"; fi"
            : ":"
        try install(
            name: "xcodebuild",
            script: """
            echo "xcodebuild $@" >> "\(log.path)"
            if [ "$1" = "-list" ]; then
            echo '{"project":{"schemes":["\(appTarget)","\(testTarget)"],"targets":["\(appTarget)","\(testTarget)"]}}'
            exit 0
            fi
            prev=""
            for a in "$@"; do
            \(bundleLine)
            prev="$a"
            done
            exit 0
            """,
            log: log, in: bin)
        let xccovBranch: String
        if let archiveJSON, let reportJSON {
            xccovBranch = """
            if [ "$3" = "--archive" ]; then
            sed "s#__ROOT__#$(pwd -P)#" <<'XCCOV_JSON'
            \(archiveJSON)
            XCCOV_JSON
            exit 0
            fi
            if [ "$3" = "--report" ]; then
            sed "s#__ROOT__#$(pwd -P)#" <<'XCCOV_JSON'
            \(reportJSON)
            XCCOV_JSON
            exit 0
            fi
            """
        } else {
            xccovBranch = """
            if [ "$1" = "xccov" ]; then exit 1; fi
            """
        }
        try install(
            name: "xcrun",
            script: """
            echo "xcrun $@" >> "\(log.path)"
            \(xccovBranch)
            cat <<'XCRESULT_JSON'
            \(xcresultJSON)
            XCRESULT_JSON
            exit 0
            """,
            log: log, in: bin)
        xcode.launchEnvironment = ["PATH": bin.path + ":/bin:/usr/bin"]

        let workspace = IDEWorkspace()
        let provider = IDEXcodeRunProvider(xcode: xcode, workspace: workspace)
        let testFile = root
            .appendingPathComponent("Tests/\(testTarget).swift", isDirectory: false)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: testFile.path),
            "the template emits \(testTarget).swift")
        return Fixture(
            directory: directory, root: root, workspace: workspace, xcode: xcode,
            provider: provider, argumentLog: log, appTarget: appTarget, testTarget: testTarget,
            testFile: testFile)
    }

    private func xcresultJSON(target: String, failing message: String?) -> String {
        let failure = message.map {
            """
            ,
                          "failureSummaries": [{"message": "\($0)", "fileName": "\(target).swift", "lineNumber": 8}]
            """
        } ?? ""
        return """
        {
          "devices": [{"deviceId": "fake", "deviceName": "Fake Mac", "platform": "macOS"}],
          "testNodes": [
            {
              "nodeIdentifier": "target-1",
              "nodeType": "Unit test bundle",
              "name": "\(target)",
              "result": "Failed",
              "duration": "0.05s",
              "children": [
                {
                  "nodeIdentifier": "suite-1",
                  "nodeType": "Test Suite",
                  "name": "\(target).\(target)",
                  "result": "Failed",
                  "duration": "0.05s",
                  "children": [
                    {
                      "nodeIdentifier": "case-1",
                      "nodeType": "Test Case",
                      "name": "testExample()",
                      "result": "Passed",
                      "duration": "0.01s"
                    },
                    {
                      "nodeIdentifier": "case-2",
                      "nodeType": "Test Case",
                      "name": "testPerformanceExample()",
                      "result": "Failed",
                      "duration": "0.04s"\(failure)
                    }
                  ]
                }
              ]
            }
          ]
        }
        """
    }

    private func tearDown(_ fixture: Fixture) {
        // Runs keep their bundles in the project cache, never in the fixture directory.
        try? FileManager.default.removeItem(at: IDEXcodeRunProvider.cacheFolder(for: fixture.root))
        fixture.xcode.stop()
        fixture.workspace.teardown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func document(_ url: URL) throws -> IDERunDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        return IDERunDocument(url: url, languageIdentifier: "swift", caretUTF16Offset: 0, text: text)
    }

    // MARK: Schemes

    func testSchemesListWithoutTrust() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-xcode-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.xcode.macos-app"))
        let root = try IDEProjectWriter.create(
            template, options: IDENewProjectOptions(name: "FlowApp", parentDirectory: directory))
        let store = ProjectTrustStore(storeURL: directory.appendingPathComponent("flow-trust.json"))
        let xcode = IDEXcodeProjectSystem(status: IDEProjectStatus(), trustStore: store)
        defer { xcode.stop() }
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("args.log")
        try install(
            name: "xcodebuild",
            script: """
            echo "xcodebuild $@" >> "\(log.path)"
            echo '{"project":{"schemes":["FlowApp","FlowAppTests"],"targets":["FlowApp","FlowAppTests"]}}'
            exit 0
            """,
            log: log, in: bin)
        xcode.launchEnvironment = ["PATH": bin.path + ":/bin:/usr/bin"]
        xcode.projectDidChange(root: root)

        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        let provider = IDEXcodeRunProvider(xcode: xcode, workspace: workspace)
        let schemes = await provider.schemes()
        XCTAssertEqual(schemes, ["FlowApp", "FlowAppTests"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path),
            "listing schemes runs xcodebuild")
        XCTAssertFalse(store.isTrusted(root), "listing schemes never grants trust")
    }

    // MARK: Running

    func testRunTestsFillsTestResultsFromXCResultTool() async throws {
        let fixture = try makeFixture(xcresultJSON: xcresultJSON(
            target: "FlowAppTests", failing: "XCTAssertEqual failed"))
        defer { tearDown(fixture) }
        fixture.provider.selectedScheme = fixture.testTarget
        let filter = "\(fixture.testTarget)/\(fixture.testTarget)/testExample"
        fixture.provider.runTests(title: fixture.testTarget, filters: [filter])

        let finished = await waitUntil {
            fixture.workspace.testResults.cases.count == 2 && !fixture.xcode.isRunningTasks
        }
        XCTAssertTrue(finished, fixture.workspace.testResults.summaryMessage ?? "no summary")
        XCTAssertEqual(fixture.workspace.testResults.passedCount, 1)
        XCTAssertEqual(fixture.workspace.testResults.failedCount, 1)
        XCTAssertTrue(fixture.workspace.testResults.canRerun)
        XCTAssertTrue(fixture.workspace.testResults.canRerunFailed)
        let failed = try XCTUnwrap(
            fixture.workspace.testResults.cases.first { $0.status == .failed })
        XCTAssertEqual(failed.className, fixture.testTarget)
        XCTAssertEqual(failed.name, "testPerformanceExample()")
        XCTAssertTrue(failed.message?.contains("XCTAssertEqual failed") ?? false,
            failed.message ?? "no message")

        let log = try String(contentsOf: fixture.argumentLog, encoding: .utf8)
        XCTAssertTrue(log.contains("-project \(fixture.root.path)/FlowApp.xcodeproj"), log)
        XCTAssertTrue(log.contains("-scheme \(fixture.testTarget)"), log)
        XCTAssertTrue(log.contains("-destination platform=macOS"), log)
        XCTAssertTrue(log.contains("-derivedDataPath"), log)
        XCTAssertTrue(log.contains("-only-testing \(filter)"), log)
        XCTAssertTrue(log.contains("-resultBundlePath"), log)
        XCTAssertFalse(log.contains("-enableCodeCoverage"), "a plain run is not instrumented")
        XCTAssertTrue(log.contains("get test-results tests --path"), log)

        let bundle = try XCTUnwrap(fixture.provider.lastResultBundle)
        XCTAssertEqual(
            bundle.deletingLastPathComponent(),
            IDEXcodeRunProvider.cacheFolder(for: fixture.root),
            "the passing run keeps its bundle in the project cache for the coverage step")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }

    func testRerunFailedRunsOnlyTheFailures() async throws {
        let fixture = try makeFixture(xcresultJSON: xcresultJSON(
            target: "FlowAppTests", failing: "XCTAssertEqual failed"))
        defer { tearDown(fixture) }
        fixture.provider.selectedScheme = fixture.testTarget
        let filter = "\(fixture.testTarget)/\(fixture.testTarget)/testExample"
        fixture.provider.runTests(title: fixture.testTarget, filters: [filter])
        let finished = await waitUntil {
            fixture.workspace.testResults.cases.count == 2 && !fixture.xcode.isRunningTasks
        }
        XCTAssertTrue(finished)

        fixture.workspace.rerunTests(failedOnly: true)
        let reran = await waitUntil {
            ((try? String(contentsOf: fixture.argumentLog, encoding: .utf8)) ?? "")
                .contains("-only-testing \(fixture.testTarget)/\(fixture.testTarget)/testPerformanceExample")
        }
        XCTAssertTrue(reran, "rerun asks for just the failure, without the () suffix")

        fixture.workspace.rerunTests(failedOnly: false)
        let reranAll = await waitUntil {
            let log = (try? String(contentsOf: fixture.argumentLog, encoding: .utf8)) ?? ""
            return log.components(separatedBy: "-only-testing \(filter)").count >= 3
        }
        XCTAssertTrue(reranAll, "rerunning everything repeats the original filter")
    }

    func testRunningAGroupRunsTheWholeTarget() async throws {
        let fixture = try makeFixture(xcresultJSON: xcresultJSON(
            target: "FlowAppTests", failing: nil))
        defer { tearDown(fixture) }
        fixture.provider.selectedScheme = fixture.testTarget
        let doc = try document(fixture.testFile)
        let places = await fixture.provider.runnableLocations(in: doc)
        let group = try XCTUnwrap(places.first { $0.kind == .testGroup })
        fixture.provider.run(doc, location: group, mode: .run)

        let finished = await waitUntil {
            fixture.workspace.testResults.cases.count == 2 && !fixture.xcode.isRunningTasks
        }
        XCTAssertTrue(finished)
        let log = try String(contentsOf: fixture.argumentLog, encoding: .utf8)
        XCTAssertTrue(
            log.contains("-only-testing \(fixture.testTarget)/\(fixture.testTarget)\n"),
            "a group runs its whole test target: \(log)")
    }

    func testRunTestsRefusesWhileUntrusted() async throws {
        let fixture = try makeFixture(
            xcresultJSON: xcresultJSON(target: "FlowAppTests", failing: nil), trusted: false)
        defer { tearDown(fixture) }
        fixture.provider.selectedScheme = fixture.testTarget
        fixture.provider.runTests(title: "X", filters: ["Foo/Bar/testBaz"])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.argumentLog.path),
            "no trust, no xcodebuild")
        XCTAssertFalse(fixture.xcode.isRunningTasks)
        XCTAssertTrue(fixture.workspace.testResults.cases.isEmpty)
    }

    func testSuccessWithoutABundleSaysSo() async throws {
        let fixture = try makeFixture(
            xcresultJSON: xcresultJSON(target: "FlowAppTests", failing: nil), makeBundle: false)
        defer { tearDown(fixture) }
        fixture.provider.selectedScheme = fixture.testTarget
        fixture.provider.runTests(title: fixture.testTarget, filters: [])
        let stopped = await waitUntil {
            !fixture.xcode.isRunningTasks
                && (fixture.workspace.testResults.summaryMessage?
                    .contains("no result bundle") ?? false)
        }
        XCTAssertTrue(stopped, fixture.workspace.testResults.summaryMessage ?? "no summary")
        XCTAssertNil(fixture.provider.lastResultBundle)
    }

    // MARK: Coverage

    /// Served by the fake `xccov` with `__ROOT__` resolved to the project (its working directory).
    private func coverageArchive() -> String {
        """
        {"__ROOT__/FlowApp/ContentView.swift": [
          {"line": 10, "isExecutable": true, "executionCount": 2},
          {"line": 11, "isExecutable": true, "executionCount": 0},
          {"line": 12, "isExecutable": false}
        ]}
        """
    }

    private func coverageReport() -> String {
        """
        {"targets": [{"name": "FlowApp.app", "files": [{
          "path": "__ROOT__/FlowApp/ContentView.swift",
          "coveredLines": 1, "executableLines": 2,
          "functions": [{"executionCount": 1}]}]}]}
        """
    }

    func testCoverageRunPublishesBands() async throws {
        let fixture = try makeFixture(
            xcresultJSON: xcresultJSON(target: "FlowAppTests", failing: nil),
            archiveJSON: coverageArchive(), reportJSON: coverageReport())
        defer { tearDown(fixture) }
        fixture.provider.selectedScheme = fixture.testTarget
        fixture.provider.runTests(
            title: fixture.testTarget, filters: ["\(fixture.testTarget)"], coverage: true)

        let done = await waitUntil {
            fixture.workspace.coverage.snapshot != nil && !fixture.xcode.isRunningTasks
        }
        XCTAssertTrue(done, fixture.workspace.coverage.failureMessage ?? "no snapshot")
        let snapshot = try XCTUnwrap(fixture.workspace.coverage.snapshot)
        XCTAssertEqual(snapshot.label, fixture.testTarget)
        XCTAssertEqual(snapshot.report.packages.map(\.name), ["FlowApp"])
        XCTAssertEqual(snapshot.report.totals.lines, JavaCoverageCounter(missed: 1, covered: 1))
        let view = fixture.root.resolvingSymlinksInPath().appendingPathComponent("FlowApp/ContentView.swift")
        XCTAssertFalse(fixture.workspace.coverage.bands(forFile: view).isEmpty,
            "the editor paints the file's bands")

        let log = try String(contentsOf: fixture.argumentLog, encoding: .utf8)
        XCTAssertTrue(log.contains("-enableCodeCoverage YES"), log)
    }

    func testARunWithoutCoverageDataSaysSoInTheCoverageTab() async throws {
        let fixture = try makeFixture(xcresultJSON: xcresultJSON(target: "FlowAppTests", failing: nil))
        defer { tearDown(fixture) }
        fixture.provider.selectedScheme = fixture.testTarget
        fixture.provider.runTests(
            title: fixture.testTarget, filters: ["\(fixture.testTarget)"], coverage: true)

        let failed = await waitUntil { fixture.workspace.coverage.failureMessage != nil }
        XCTAssertTrue(failed, "xccov answered nothing")
        XCTAssertNil(fixture.workspace.coverage.snapshot)
        XCTAssertTrue(fixture.workspace.coverage.failureMessage?.contains("xccov") ?? false,
            fixture.workspace.coverage.failureMessage ?? "no message")
    }

    func testARunWithCoverageFromTheMenuUsesAllTestTargets() async throws {
        let fixture = try makeFixture(
            xcresultJSON: xcresultJSON(target: "FlowAppTests", failing: nil),
            archiveJSON: coverageArchive(), reportJSON: coverageReport())
        defer { tearDown(fixture) }
        fixture.provider.selectedScheme = fixture.testTarget

        XCTAssertTrue(fixture.provider.runTestsInstrumented(.coverage, document: nil))
        let done = await waitUntil {
            fixture.workspace.coverage.snapshot != nil && !fixture.xcode.isRunningTasks
        }
        XCTAssertTrue(done, fixture.workspace.coverage.failureMessage ?? "no snapshot")
        let log = try String(contentsOf: fixture.argumentLog, encoding: .utf8)
        XCTAssertTrue(log.contains("-only-testing \(fixture.testTarget)"), log)
        XCTAssertTrue(log.contains("-enableCodeCoverage YES"), log)
    }

    func testTheGutterOffersCoverageForTestsButNotPreviews() async throws {
        let fixture = try makeFixture(xcresultJSON: xcresultJSON(target: "FlowAppTests", failing: nil))
        defer { tearDown(fixture) }
        XCTAssertTrue(fixture.provider.supportsInstrumentation(at: IDERunnableLocation(kind: .test, line: 4, title: "t")))
        XCTAssertTrue(fixture.provider.supportsInstrumentation(at: IDERunnableLocation(kind: .testGroup, line: 3, title: "g")))
        XCTAssertFalse(fixture.provider.supportsInstrumentation(at: IDERunnableLocation(kind: .preview(index: 0), line: 1, title: "p")))
    }

    func testProfileIsNotAvailableYet() async throws {
        let fixture = try makeFixture(xcresultJSON: xcresultJSON(target: "FlowAppTests", failing: nil))
        defer { tearDown(fixture) }
        XCTAssertTrue(fixture.provider.runInstrumented(.profile, document: nil))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(fixture.xcode.isRunningTasks, "no build starts")
    }

    // MARK: Context

    func testTestFileContextAndGutter() async throws {
        let fixture = try makeFixture(xcresultJSON: xcresultJSON(
            target: "FlowAppTests", failing: nil))
        defer { tearDown(fixture) }
        let doc = try document(fixture.testFile)
        XCTAssertTrue(fixture.provider.canRun(doc))
        XCTAssertEqual(fixture.provider.runHelp(fileURL: fixture.testFile), "Run tests")
        XCTAssertFalse(fixture.provider.canDebug(fileURL: fixture.testFile))

        let places = await fixture.provider.runnableLocations(in: doc)
        XCTAssertEqual(places.map(\.kind), [.testGroup, .test, .test])
        XCTAssertEqual(places.map(\.title),
            [fixture.testTarget, "testExample()", "testPerformanceExample()"])
        let filter = fixture.provider.testFilter(
            for: try XCTUnwrap(places.first { $0.title == "testExample()" }), in: doc)
        XCTAssertEqual(filter, "\(fixture.testTarget)/\(fixture.testTarget)/testExample")

        let appFile = fixture.root.appendingPathComponent("FlowApp/FlowAppApp.swift")
        XCTAssertFalse(fixture.provider.canRun(try document(appFile)))
        XCTAssertEqual(fixture.provider.runHelp(fileURL: appFile),
            "Run (no test target holds this file)")
    }

    // MARK: Real toolchain

    /// The generated template against real `xcodebuild`/`xcrun`: scheme autocreation, a
    /// destination-free run, and the parser against genuine `xcresulttool` JSON. With
    /// `TEST_FIXTURES=1` the bundle's JSON refreshes the `XcodeTests/TestResults.json` fixture.
    func testRealTemplateTestsPassWithTheRealToolchain() async throws {
        guard IDEXcodeProjectSystem.resolveXcodebuild(environment: nil) != nil else {
            throw XCTSkip("Needs Xcode installed.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-xcode-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.xcode.macos-app"))
        let root = try IDEProjectWriter.create(
            template, options: IDENewProjectOptions(name: "FlowApp", parentDirectory: directory))
        let store = ProjectTrustStore(storeURL: directory.appendingPathComponent("flow-trust.json"))
        store.setTrusted(true, for: root)
        let xcode = IDEXcodeProjectSystem(status: IDEProjectStatus(), trustStore: store)
        defer {
            xcode.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        xcode.projectDidChange(root: root)
        let model = try XCTUnwrap(xcode.model)
        let testTarget = try XCTUnwrap(model.targets.first { $0.kind == .test }?.name)

        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        let provider = IDEXcodeRunProvider(xcode: xcode, workspace: workspace)
        defer {
            if let bundle = provider.lastResultBundle {
                try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
            }
        }
        let schemes = await provider.schemes()
        let scheme = try XCTUnwrap(schemes.first { $0 == testTarget },
            "xcodebuild autocreates a scheme per target, got: \(schemes)")
        provider.selectedScheme = scheme
        provider.runTests(title: scheme, filters: [])
        let finished = await waitUntil(seconds: 600) {
            workspace.testResults.cases.count == 2 && !xcode.isRunningTasks
        }
        XCTAssertTrue(finished, workspace.testResults.summaryMessage ?? "no summary")
        XCTAssertEqual(workspace.testResults.passedCount, 2)
        XCTAssertEqual(workspace.testResults.failedCount, 0)

        if ProcessInfo.processInfo.environment["TEST_FIXTURES"] == "1" {
            let bundle = try XCTUnwrap(provider.lastResultBundle)
            let raw = await provider.testResultData(bundle: bundle)
            let data = try XCTUnwrap(raw)
            let thisFile = URL(fileURLWithPath: #filePath)
            let repoRoot = thisFile
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let fixtureURL = repoRoot
                .appendingPathComponent("Tests/PenumbraTests/Fixtures/XcodeTests/TestResults.json")
            try data.write(to: fixtureURL)
        }

        // One method through the gutter's selector, against the real toolchain: this is the
        // `-only-testing <target>/<class>/<method>` shape Rerun Failed relies on.
        provider.runTests(title: "testExample", filters: ["\(testTarget)/\(testTarget)/testExample"])
        let singledOut = await waitUntil(seconds: 600) {
            workspace.testResults.cases.count == 1 && !xcode.isRunningTasks
        }
        XCTAssertTrue(singledOut, workspace.testResults.summaryMessage ?? "no summary")
        XCTAssertEqual(workspace.testResults.passedCount, 1)
        XCTAssertEqual(workspace.testResults.failedCount, 0)

        if ProcessInfo.processInfo.environment["XCLIST_FIXTURES"] == "1" {
            let raw = await provider.listData()
            let data = try XCTUnwrap(raw)
            let thisFile = URL(fileURLWithPath: #filePath)
            let repoRoot = thisFile
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let fixtureURL = repoRoot
                .appendingPathComponent("Tests/PenumbraTests/Fixtures/XcodeTests/XcodeList.json")
            try data.write(to: fixtureURL)
        }
    }

    /// The template tests with coverage, against the real toolchain: `-enableCodeCoverage YES`,
    /// `xccov` on the bundle, and the snapshot the Coverage tab paints. With `XCCOV_FIXTURES=1`
    /// the bundle's archive and report JSON refresh the `XcodeTests` fixtures (machine paths
    /// sanitized to `/example`); with `XCSHOWBUILDSETTINGS_FIXTURES=1` the app scheme's build
    /// settings refresh `ShowBuildSettings.json` (the home directory sanitized).
    func testRealCoverageMeasuresTheTemplateTests() async throws {
        guard IDEXcodeProjectSystem.resolveXcodebuild(environment: nil) != nil else {
            throw XCTSkip("Needs Xcode installed.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-xcode-cov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.xcode.macos-app"))
        let root = try IDEProjectWriter.create(
            template, options: IDENewProjectOptions(name: "ProbeApp", parentDirectory: directory))
        let store = ProjectTrustStore(storeURL: directory.appendingPathComponent("flow-trust.json"))
        store.setTrusted(true, for: root)
        let xcode = IDEXcodeProjectSystem(status: IDEProjectStatus(), trustStore: store)
        defer {
            xcode.stop()
            try? FileManager.default.removeItem(at: IDEXcodeRunProvider.cacheFolder(for: root))
            try? FileManager.default.removeItem(at: directory)
        }
        xcode.projectDidChange(root: root)
        let model = try XCTUnwrap(xcode.model)
        let testTarget = try XCTUnwrap(model.targets.first { $0.kind == .test }?.name)
        let appTarget = try XCTUnwrap(model.targets.first { $0.kind == .application }?.name)

        // The template's tests cover only themselves, which the coverage preference
        // leaves out by default; measuring them needs the same opt-in as the Java pane.
        let preferences = IDEPreferences.shared
        let includedTestsBefore = preferences.javaCoverageIncludesTests
        preferences.javaCoverageIncludesTests = true
        defer { preferences.javaCoverageIncludesTests = includedTestsBefore }

        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        let provider = IDEXcodeRunProvider(xcode: xcode, workspace: workspace)
        provider.runTests(title: testTarget, filters: [], coverage: true)
        let done = await waitUntil(seconds: 600) {
            workspace.coverage.snapshot != nil && !xcode.isRunningTasks
        }
        XCTAssertTrue(done, workspace.coverage.failureMessage ?? "no snapshot")
        let snapshot = try XCTUnwrap(workspace.coverage.snapshot)
        XCTAssertGreaterThan(snapshot.report.totals.lines.covered, 0)
        let testFile = root.appendingPathComponent("Tests/\(testTarget).swift")
        XCTAssertFalse(workspace.coverage.bands(forFile: testFile).isEmpty,
            "the editor paints the template tests' bands")

        let environment = ProcessInfo.processInfo.environment
        if environment["XCCOV_FIXTURES"] == "1" {
            let bundle = try XCTUnwrap(provider.lastResultBundle)
            let rawArchive = await provider.xccov(bundle: bundle, kind: "archive", environment: nil)
            let archive = try XCTUnwrap(rawArchive)
            let rawReport = await provider.xccov(bundle: bundle, kind: "report", environment: nil)
            let report = try XCTUnwrap(rawReport)
            let thisFile = URL(fileURLWithPath: #filePath)
            let repoRoot = thisFile
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let fixtures = repoRoot.appendingPathComponent("Tests/PenumbraTests/Fixtures/XcodeTests")
            // xccov escapes slashes, so both the plain and the escaped prefix are replaced.
            let escapedRoot = directory.path.replacingOccurrences(of: "/", with: "\\/")
            func sanitize(_ text: String) -> String {
                text.replacingOccurrences(of: directory.path, with: "/example")
                    .replacingOccurrences(of: escapedRoot, with: "/example")
            }
            try sanitize(String(decoding: archive, as: UTF8.self))
                .write(to: fixtures.appendingPathComponent("XCCovArchive.json"),
                    atomically: true, encoding: .utf8)
            try sanitize(String(decoding: report, as: UTF8.self))
                .write(to: fixtures.appendingPathComponent("XCCovReport.json"),
                    atomically: true, encoding: .utf8)
        }
        if environment["XCSHOWBUILDSETTINGS_FIXTURES"] == "1" {
            var request = SubprocessRequest(
                executable: "/usr/bin/xcodebuild",
                arguments: XcodeTestCommand.showBuildSettingsArguments(
                    project: model.projectURL, scheme: appTarget)
            )
            request.workingDirectory = root
            request.timeout = .seconds(120)
            let result = try await SubprocessRunner.run(request)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let thisFile = URL(fileURLWithPath: #filePath)
            let repoRoot = thisFile
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            try result.stdout.text
                .replacingOccurrences(of: directory.path, with: "/example")
                .replacingOccurrences(of: home, with: "/Users/example")
                .write(to: repoRoot.appendingPathComponent(
                    "Tests/PenumbraTests/Fixtures/XcodeTests/ShowBuildSettings.json"),
                    atomically: true, encoding: .utf8)
        }
    }
}
