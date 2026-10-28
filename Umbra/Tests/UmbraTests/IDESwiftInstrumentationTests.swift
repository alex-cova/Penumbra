import Foundation
import JavaIntelligence
import SwiftIntelligence
import XCTest
@testable import Umbra

/// Run Tests with Coverage and Profile for Swift: SwiftPM through a fake `swift`, and a real `xctrace` recording.
@MainActor
final class IDESwiftInstrumentationTests: XCTestCase {
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
        name: "Shapes",
        targets: [.target(name: "Shapes"), .testTarget(name: "ShapesTests", dependencies: ["Shapes"])]
    )
    """

    private struct Fixture {
        var directory: URL
        var root: URL
        var workspace: IDEWorkspace
        var system: IDESwiftPMProjectSystem
        var provider: IDESwiftRunProvider
        var argumentLog: URL
    }

    /// A package whose `swift` prints `codecovPath` (or nothing) for `--show-codecov-path` and succeeds otherwise.
    private func makeFixture(coverageJSON: Bool) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-swift-cov-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("pkg", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("Sources/Shapes"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("Tests/ShapesTests"), withIntermediateDirectories: true)
        try manifest.write(to: root.appendingPathComponent("Package.swift"), atomically: false, encoding: .utf8)
        let area = root.appendingPathComponent("Sources/Shapes/Area.swift")
        try "public struct Rectangle {}\n".write(to: area, atomically: false, encoding: .utf8)

        // The fixture was exported from a package at /proj; point it at this one.
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tests/PenumbraTests/Fixtures/SwiftCoverage/shapes.json")
        let json = try String(contentsOf: fixtureURL, encoding: .utf8).replacingOccurrences(of: "/proj", with: root.path)
        let jsonFile = directory.appendingPathComponent("Shapes.json")
        try json.write(to: jsonFile, atomically: false, encoding: .utf8)

        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("args.log")
        let swift = bin.appendingPathComponent("swift")
        let answer = coverageJSON ? "echo \"\(jsonFile.path)\"" : "echo \"error: no coverage data\"; exit 1"
        let script = "#!/bin/sh\necho \"$@\" >> \"\(log.path)\"\ncase \"$*\" in *--show-codecov-path*) \(answer);; *) exit 0;; esac\n"
        try script.write(to: swift, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)

        let store = ProjectTrustStore(storeURL: directory.appendingPathComponent("swiftpm-trust.json"))
        store.setTrusted(true, for: root)
        let system = IDESwiftPMProjectSystem(status: IDEProjectStatus(), trustStore: store)
        system.launchEnvironment = ["PATH": bin.path + ":/bin:/usr/bin"]
        let workspace = IDEWorkspace()
        let provider = IDESwiftRunProvider(swiftPM: system, workspace: workspace)
        system.projectDidChange(root: root)
        return Fixture(directory: directory, root: root, workspace: workspace, system: system, provider: provider, argumentLog: log)
    }

    private func tearDown(_ fixture: Fixture) {
        fixture.system.stop()
        fixture.workspace.teardown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func waitUntil(seconds: Double = 15, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - Coverage

    func testRunTestsWithCoverageTurnsItOnAndPublishesTheReport() async throws {
        let fixture = try makeFixture(coverageJSON: true)
        defer { tearDown(fixture) }
        _ = await waitUntil { fixture.system.manifest != nil }

        fixture.provider.runTests(title: "ShapesTests", filters: ["ShapesTests."], coverage: true)
        let published = await waitUntil { fixture.workspace.coverage.snapshot != nil }
        XCTAssertTrue(published, fixture.workspace.coverage.failureMessage ?? "no report")

        let log = try String(contentsOf: fixture.argumentLog, encoding: .utf8)
        XCTAssertTrue(log.contains("test --enable-code-coverage --filter ShapesTests."), log)
        XCTAssertTrue(log.contains("test --show-codecov-path"), log)

        let snapshot = try XCTUnwrap(fixture.workspace.coverage.snapshot)
        XCTAssertEqual(snapshot.report.packages.map(\.name), ["Shapes"])
        XCTAssertEqual(snapshot.label, "ShapesTests")
        XCTAssertFalse(snapshot.supportsJaCoCoExports, "a Swift report has no JaCoCo HTML or XML to export")
        let area = fixture.root.appendingPathComponent("Sources/Shapes/Area.swift")
        XCTAssertFalse(fixture.workspace.coverage.bands(forFile: area).isEmpty, "the editor paints the file's bands")
    }

    func testARunWithoutCoverageDataSaysSoInTheCoverageTab() async throws {
        let fixture = try makeFixture(coverageJSON: false)
        defer { tearDown(fixture) }
        _ = await waitUntil { fixture.system.manifest != nil }

        fixture.provider.runTests(title: "ShapesTests", filters: ["ShapesTests."], coverage: true)
        let failed = await waitUntil { fixture.workspace.coverage.failureMessage != nil }
        XCTAssertTrue(failed)
        XCTAssertNil(fixture.workspace.coverage.snapshot)
        XCTAssertTrue(fixture.workspace.coverage.failureMessage?.contains("no coverage data") ?? false)
    }

    func testAPlainTestRunDoesNotAskForCoverage() async throws {
        let fixture = try makeFixture(coverageJSON: true)
        defer { tearDown(fixture) }
        _ = await waitUntil { fixture.system.manifest != nil }

        fixture.provider.runTests(title: "ShapesTests", filters: ["ShapesTests."])
        _ = await waitUntil { !fixture.system.isRunningTasks && (try? String(contentsOf: fixture.argumentLog, encoding: .utf8))?.contains("test") == true }
        let log = (try? String(contentsOf: fixture.argumentLog, encoding: .utf8)) ?? ""
        XCTAssertFalse(log.contains("--enable-code-coverage"), log)
        XCTAssertNil(fixture.workspace.coverage.snapshot)
    }

    func testRunTestsWithCoverageFromTheMenuUsesTheTestTargetsOrAllOfThem() async throws {
        let fixture = try makeFixture(coverageJSON: true)
        defer { tearDown(fixture) }
        _ = await waitUntil { fixture.system.manifest != nil }

        XCTAssertTrue(fixture.provider.runTestsInstrumented(.coverage, document: nil))
        _ = await waitUntil { fixture.workspace.coverage.snapshot != nil }
        let log = try String(contentsOf: fixture.argumentLog, encoding: .utf8)
        XCTAssertTrue(log.contains("--filter ShapesTests."), "every test target of the package: \(log)")
    }

    func testTheGutterOffersCoverageAndProfileForTestsAndProgramsButNotPreviews() {
        let workspace = IDEWorkspace()
        let provider = IDESwiftRunProvider(swiftPM: workspace.swiftPM, workspace: workspace)
        XCTAssertTrue(provider.supportsInstrumentation(at: IDERunnableLocation(kind: .test, line: 3, title: "t")))
        XCTAssertTrue(provider.supportsInstrumentation(at: IDERunnableLocation(kind: .entryPoint, line: 3, title: "main")))
        XCTAssertFalse(provider.supportsInstrumentation(at: IDERunnableLocation(kind: .preview(index: 0), line: 3, title: "p")))
    }

    // MARK: - Profile (a real recording)

    func testATimeProfilerRecordingBecomesAProfile() async throws {
        let find = Process()
        find.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        find.arguments = ["--find", "xctrace"]
        find.standardOutput = Pipe()
        find.standardError = Pipe()
        try find.run()
        find.waitUntilExit()
        try XCTSkipIf(find.terminationStatus != 0, "No xctrace on this machine")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-xctrace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("spin.swift")
        try "func fib(_ n: Int) -> Int { n < 2 ? n : fib(n - 1) + fib(n - 2) }\nprint(fib(38))\n".write(to: source, atomically: true, encoding: .utf8)
        let binary = directory.appendingPathComponent("spin")
        let compile = try await run("/usr/bin/xcrun", ["swiftc", "-O", source.path, "-o", binary.path])
        try XCTSkipIf(compile != 0, "swiftc could not build the sample program")

        let trace = directory.appendingPathComponent("spin.trace")
        let recorded = try await run("/usr/bin/xcrun", SwiftProfileCommand.recordArguments(trace: trace, executable: binary))
        try XCTSkipIf(recorded != 0 || !FileManager.default.fileExists(atPath: trace.path), "xctrace could not record here (no permission to profile)")

        let profile = try await IDESwiftRunProvider.loadTimeProfile(trace: trace)
        XCTAssertGreaterThan(profile.cpuSamples, 5)
        let hot = try XCTUnwrap(profile.cpu.hotMethods(symbols: profile.symbols).first)
        XCTAssertTrue(profile.symbols.methods[Int(hot.method)].name.hasPrefix("fib"), profile.symbols.methods[Int(hot.method)].name)
        XCTAssertEqual(profile.symbols.methods[Int(hot.method)].className, "spin")
    }

    private func run(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}
