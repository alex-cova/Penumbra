import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// Run and tests for Swift through SwiftPM, against a fake `swift` on PATH.
@MainActor
final class IDESwiftRunProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private let manifest = """
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(
        name: "App",
        targets: [
            .executableTarget(name: "App"),
            .testTarget(name: "AppTests", dependencies: ["App"])
        ]
    )
    """

    private let testSource = """
    import XCTest
    @testable import App

    final class MathTests: XCTestCase {
        func testAdd() { XCTAssertEqual(1 + 1, 2) }
        func testSubtract() { XCTAssertEqual(2 - 1, 1) }
        func helper() {}
    }

    @Suite struct ParserTests {
        @Test func parses() {}
    }
    """

    private func waitUntil(seconds: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private struct Fixture {
        var directory: URL
        var root: URL
        var workspace: IDEWorkspace
        var system: IDESwiftPMProjectSystem
        var provider: IDESwiftRunProvider
        var argumentLog: URL
        var testFile: URL
        var mainFile: URL
    }

    private func makeFixture(swiftScript: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-swift-run-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("pkg", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("Tests/AppTests"), withIntermediateDirectories: true)
        try manifest.write(to: root.appendingPathComponent("Package.swift"), atomically: false, encoding: .utf8)
        let mainFile = root.appendingPathComponent("Sources/App/main.swift")
        try "print(\"hello\")\n".write(to: mainFile, atomically: false, encoding: .utf8)
        let testFile = root.appendingPathComponent("Tests/AppTests/MathTests.swift")
        try testSource.write(to: testFile, atomically: false, encoding: .utf8)

        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("args.log")
        let swift = bin.appendingPathComponent("swift")
        try "#!/bin/sh\necho \"$@\" >> \"\(log.path)\"\n\(swiftScript)\n".write(to: swift, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)

        let store = GradleTrustStore(storeURL: directory.appendingPathComponent("swiftpm-trust.json"))
        store.setTrusted(true, for: root)
        let system = IDESwiftPMProjectSystem(status: IDEProjectStatus(), trustStore: store)
        system.launchEnvironment = ["PATH": bin.path + ":/bin:/usr/bin"]
        let workspace = IDEWorkspace()
        let provider = IDESwiftRunProvider(swiftPM: system, workspace: workspace)
        system.projectDidChange(root: root)
        return Fixture(
            directory: directory, root: root, workspace: workspace, system: system, provider: provider,
            argumentLog: log, testFile: testFile, mainFile: mainFile
        )
    }

    private func tearDown(_ fixture: Fixture) {
        fixture.system.stop()
        fixture.workspace.teardown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func document(_ url: URL, caretLine: Int = 0) throws -> IDERunDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        var offset = 0
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where index < caretLine {
            offset += line.utf16.count + 1
        }
        return IDERunDocument(url: url, languageIdentifier: "swift", caretUTF16Offset: offset, text: text)
    }

    // MARK: Availability and places

    func testRunAppliesToAnExecutableTargetAndToATestTarget() throws {
        let fixture = try makeFixture(swiftScript: "exit 0")
        defer { tearDown(fixture) }
        XCTAssertTrue(fixture.provider.canRun(try document(fixture.mainFile)))
        XCTAssertTrue(fixture.provider.canRun(try document(fixture.testFile)))
        XCTAssertFalse(fixture.provider.canDebug(fileURL: fixture.mainFile))
        XCTAssertEqual(fixture.provider.runHelp(fileURL: fixture.mainFile), "Run App")
        XCTAssertEqual(fixture.provider.runHelp(fileURL: fixture.testFile), "Run tests of AppTests")
        let elsewhere = IDERunDocument(url: fixture.root.appendingPathComponent("x.rs"), languageIdentifier: "rust", text: "")
        XCTAssertFalse(fixture.provider.canRun(elsewhere))
    }

    func testRunnablePlacesAreTheEntryPointAndEachTest() async throws {
        let fixture = try makeFixture(swiftScript: "exit 0")
        defer { tearDown(fixture) }
        let places = await fixture.provider.runnableLocations(in: try document(fixture.testFile))
        XCTAssertEqual(places.map(\.kind), [.testGroup, .test, .test, .testGroup, .test])
        XCTAssertEqual(places.map(\.title), ["MathTests", "testAdd()", "testSubtract()", "ParserTests", "parses()"])
        XCTAssertEqual(places.map(\.line), [4, 5, 6, 10, 11])
        let entry = await fixture.provider.runnableLocations(in: try document(fixture.mainFile))
        XCTAssertEqual(entry, [IDERunnableLocation(kind: .entryPoint, line: 1, title: "main")])
    }

    // MARK: Running

    func testATestMethodRunsWithItsFilterAndFillsTestResults() async throws {
        let script = """
        if [ "$1" = package ]; then exit 1; fi
        if [ "$1" = test ]; then
          for last; do :; done
          cat > "$last" <<'XML'
        <?xml version="1.0"?>
        <testsuites><testsuite name="AppTests.MathTests" tests="2">
          <testcase classname="AppTests.MathTests" name="testAdd" time="0.01"/>
          <testcase classname="AppTests.MathTests" name="testSubtract" time="0.02"><failure message="boom"/></testcase>
        </testsuite></testsuites>
        XML
          exit 1
        fi
        exit 0
        """
        let fixture = try makeFixture(swiftScript: script)
        defer { tearDown(fixture) }
        let doc = try document(fixture.testFile)
        let places = await fixture.provider.runnableLocations(in: doc)
        let add = try XCTUnwrap(places.first { $0.title == "testAdd()" })
        fixture.provider.run(doc, location: add, mode: .run)

        let finished = await waitUntil { fixture.workspace.testResults.cases.count == 2 && !fixture.system.isBusy }
        XCTAssertTrue(finished, fixture.workspace.testResults.summaryMessage ?? "no summary")
        XCTAssertEqual(fixture.workspace.testResults.failedCount, 1)
        XCTAssertEqual(fixture.workspace.testResults.passedCount, 1)
        XCTAssertTrue(fixture.workspace.testResults.canRerun)
        XCTAssertTrue(fixture.workspace.testResults.canRerunFailed)

        let log = try String(contentsOf: fixture.argumentLog, encoding: .utf8)
        XCTAssertTrue(log.contains("test --filter AppTests.MathTests/testAdd --xunit-output"), log)

        // Rerun Failed asks for just the failure.
        fixture.workspace.rerunTests(failedOnly: true)
        let reran = await waitUntil {
            ((try? String(contentsOf: fixture.argumentLog, encoding: .utf8)) ?? "")
                .contains("--filter AppTests.MathTests/testSubtract")
        }
        XCTAssertTrue(reran)
    }

    func testAProgramIsBuiltFirstAndThenRunInTheRunTab() async throws {
        let script = """
        if [ "$1" = package ]; then exit 1; fi
        if [ "$1" = build ]; then echo "Build complete"; exit 0; fi
        if [ "$1" = run ]; then echo "hello from the program"; exit 0; fi
        exit 0
        """
        let fixture = try makeFixture(swiftScript: script)
        defer { tearDown(fixture) }
        fixture.provider.run(try document(fixture.mainFile), mode: .run)

        let started = await waitUntil { !fixture.workspace.runs.sessions.isEmpty }
        XCTAssertTrue(started, fixture.system.console.lines.map(\.text).joined(separator: "\n"))
        let finished = await waitUntil {
            guard let session = fixture.workspace.runs.sessions.last else { return false }
            return !session.isActive
        }
        XCTAssertTrue(finished)
        let log = try String(contentsOf: fixture.argumentLog, encoding: .utf8)
        XCTAssertTrue(log.contains("build --product App"), log)
        XCTAssertTrue(log.contains("run --skip-build App"), log)
        XCTAssertEqual(fixture.workspace.runs.sessions.last?.title, "App")
    }

    func testAFailedBuildDoesNotStartTheProgram() async throws {
        let script = """
        if [ "$1" = package ]; then exit 1; fi
        if [ "$1" = build ]; then echo "error: nope" >&2; exit 1; fi
        exit 0
        """
        let fixture = try makeFixture(swiftScript: script)
        defer { tearDown(fixture) }
        fixture.provider.run(try document(fixture.mainFile), mode: .run)
        let done = await waitUntil { !fixture.system.isBusy && fixture.system.console.lines.contains { $0.text.contains("swift exited 1") } }
        XCTAssertTrue(done)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(fixture.workspace.runs.sessions.isEmpty)
    }
}
