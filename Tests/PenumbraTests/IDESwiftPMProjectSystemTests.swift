import EditorIntelligence
import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// SwiftPM: the manifest read from `Package.swift`, `dump-package`'s JSON, trust, a fake `swift`
/// on PATH, and the compiler's problems.
@MainActor
final class IDESwiftPMProjectSystemTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private static let manifestSource = """
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(
        name: "Demo",
        platforms: [.macOS(.v14)],
        products: [.library(name: "DemoKit", targets: ["Demo"]), .executable(name: "demo-cli", targets: ["cli"])],
        dependencies: [.package(url: "https://github.com/a/algo.git", from: "1.0.0"), .package(path: "../local")],
        targets: [
            .target(name: "Demo", dependencies: ["Core", .product(name: "Algo", package: "algo")], path: "Sources/DemoKit"),
            .executableTarget(name: "cli", dependencies: ["Demo"]),
            .testTarget(name: "DemoTests", dependencies: ["Demo"])
        ]
    )
    """

    private func waitUntil(seconds: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-swiftpm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSystem(in directory: URL) -> (IDESwiftPMProjectSystem, GradleTrustStore) {
        let store = GradleTrustStore(storeURL: directory.appendingPathComponent("swiftpm-trust.json"))
        return (IDESwiftPMProjectSystem(status: IDEProjectStatus(), trustStore: store), store)
    }

    /// An executable named `swift` first on PATH; `/bin` and `/usr/bin` stay so `sleep` resolves.
    private func installSwift(script: String, in directory: URL) throws -> [String: String] {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let swift = bin.appendingPathComponent("swift")
        try "#!/bin/sh\n\(script)\n".write(to: swift, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        return ["PATH": bin.path + ":/bin:/usr/bin"]
    }

    private func writePackage(_ source: String, in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try source.write(to: root.appendingPathComponent("Package.swift"), atomically: false, encoding: .utf8)
    }

    private func consoleText(_ system: IDESwiftPMProjectSystem) -> String {
        system.console.lines.map(\.text).joined(separator: "\n")
    }

    // MARK: Manifest

    func testPackageSwiftIsReadWithoutRunningAnything() throws {
        let manifest = try XCTUnwrap(IDESwiftPMManifest.parse(source: Self.manifestSource, folderName: "folder"))
        XCTAssertEqual(manifest.name, "Demo")
        XCTAssertFalse(manifest.isExact)
        XCTAssertEqual(manifest.targets.map(\.name), ["Demo", "cli", "DemoTests"])
        XCTAssertEqual(manifest.targets.map(\.kind), [.regular, .executable, .test])
        XCTAssertEqual(manifest.target(named: "Demo")?.path, "Sources/DemoKit")
        XCTAssertEqual(manifest.target(named: "Demo")?.dependencies, ["Core", "Algo"])
        XCTAssertEqual(manifest.products.map(\.name), ["DemoKit", "demo-cli"])
        XCTAssertEqual(manifest.products.map(\.isExecutable), [false, true])
        XCTAssertEqual(manifest.packages.map(\.name), ["algo", "local"])
        XCTAssertEqual(manifest.packages.map(\.isLocal), [false, true])
        XCTAssertEqual(manifest.executableNames, ["demo-cli", "cli"])
        XCTAssertTrue(manifest.hasTests)
        XCTAssertNil(IDESwiftPMManifest.parse(source: "let x = 1\n", folderName: "f"))
    }

    func testDumpPackageJSONIsExactAndToleratesVersions() throws {
        let json = """
        {"name":"Dyn","targets":[
          {"name":"A","type":"regular","path":null,"dependencies":[{"byName":["B",null]},{"product":["Algo","algo",null,null]}]},
          {"name":"B","type":"regular","dependencies":[]},
          {"name":"run","type":"executable","dependencies":[{"target":["A",null]}]},
          {"name":"ATests","type":"test","dependencies":[]}],
         "products":[{"name":"run","type":{"executable":null},"targets":["run"]},{"name":"AKit","type":{"library":["automatic"]},"targets":["A"]}],
         "dependencies":[{"sourceControl":[{"identity":"algo","location":{"remote":[{"urlString":"https://x/algo.git"}]}}]},
                         {"fileSystem":[{"identity":"local","path":"/tmp/local"}]}]}
        """
        let manifest = try XCTUnwrap(IDESwiftPMManifest.parse(dumpPackage: Data(json.utf8), folderName: "f"))
        XCTAssertTrue(manifest.isExact)
        XCTAssertEqual(manifest.targets.map(\.name), ["A", "B", "run", "ATests"])
        XCTAssertEqual(manifest.target(named: "A")?.dependencies, ["B", "Algo"])
        XCTAssertEqual(manifest.products.first { $0.name == "run" }?.isExecutable, true)
        XCTAssertEqual(manifest.packages.map(\.name), ["algo", "local"])
        XCTAssertEqual(manifest.packages.first?.location, "https://x/algo.git")
        XCTAssertNil(IDESwiftPMManifest.parse(dumpPackage: Data("nope".utf8), folderName: "f"))
    }

    func testTheModuleOfAFileIsTheTargetWhoseDirectoryHoldsIt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Sources/cli", isDirectory: true), withIntermediateDirectories: true
        )
        let manifest = try XCTUnwrap(IDESwiftPMManifest.parse(source: Self.manifestSource, folderName: "f"))
        let resolver = manifest.moduleResolver(root: directory)
        XCTAssertEqual(resolver(directory.appendingPathComponent("Sources/DemoKit/A.swift")), "Demo")
        XCTAssertEqual(resolver(directory.appendingPathComponent("Sources/cli/main.swift")), "cli")
        XCTAssertEqual(resolver(directory.appendingPathComponent("Tests/DemoTests/T.swift")), "DemoTests")
        XCTAssertNil(resolver(directory.appendingPathComponent("Package.swift")))
    }

    // MARK: Compiler output

    func testCompilerOutputBecomesDiagnosticsAtTheRightColumn() {
        let output = """
        Compiling Demo main.swift
        /tmp/p/Sources/Demo/main.swift:2:13: error: cannot find 'naïve' in scope
        /tmp/p/Sources/Demo/main.swift:2:13: error: cannot find 'naïve' in scope
        /tmp/p/Sources/Demo/main.swift:5:1: warning: variable 'x' was never used
        /tmp/p/Sources/Demo/other.swift:1:1: note: declared here
        error: fatalError
        """
        let messages = SwiftBuildOutputParser.parse(output)
        XCTAssertEqual(messages.count, 3, "the repeated diagnostic is dropped, the location-less line is not one")
        XCTAssertEqual(messages.map(\.severity), [.error, .warning, .note])
        let source = "let é = 1\nlet y = 2 + naïve\n"
        let diagnostics = SwiftBuildOutputParser.diagnostics(
            from: messages, baseDirectory: URL(fileURLWithPath: "/tmp/p")
        ) { url in url.lastPathComponent == "main.swift" ? source : nil }
        let main = diagnostics[URL(fileURLWithPath: "/tmp/p/Sources/Demo/main.swift")] ?? []
        let error = main.first { $0.severity == .error }
        // 1-based byte column 13 of `let y = 2 + naïve` is the `n`: 12 characters in.
        XCTAssertEqual(error?.range.start.line, 1)
        XCTAssertEqual(error?.range.start.column, 12)
        XCTAssertEqual(error?.range.end.column, 17, "the whole identifier")
        XCTAssertEqual(error?.source, "swiftc")
        XCTAssertEqual(diagnostics[URL(fileURLWithPath: "/tmp/p/Sources/Demo/other.swift")]?.first?.severity, .information)
    }

    // MARK: Project system

    func testOpeningReadsThePackageWithoutAskingAndListsItsTasks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (system, _) = makeSystem(in: directory)
        defer { system.stop() }
        var asked = 0
        system.trustPrompt = { _ in asked += 1; return false }
        var modelReports = 0
        system.onModelChanged = { manifest, _ in if manifest != nil { modelReports += 1 } }
        let root = directory.appendingPathComponent("pkg", isDirectory: true)
        try writePackage(Self.manifestSource, in: root)
        system.projectDidChange(root: root)

        XCTAssertEqual(asked, 0)
        XCTAssertGreaterThan(modelReports, 0)
        XCTAssertTrue(system.isActive)
        XCTAssertEqual(system.syncState, .synced(modules: 3, dependencies: 2))
        XCTAssertEqual(
            system.tasks.map(\.path),
            ["build", "test", "run:demo-cli", "run:cli", "resolve", "update", "clean"]
        )
        XCTAssertEqual(system.invocation(forTask: "run:cli")?.arguments, ["run", "cli"])
        XCTAssertEqual(system.invocation(forTask: "clean")?.arguments, ["package", "clean"])
        XCTAssertFalse(system.invocation(forTask: "resolve")?.collectsDiagnostics ?? true)

        try "let x = 1\n".write(to: root.appendingPathComponent("Package.swift"), atomically: false, encoding: .utf8)
        system.projectDidChange(root: root)
        XCTAssertEqual(system.syncState, .failed(summary: "Couldn't read Package.swift"))
        let plain = directory.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        system.projectDidChange(root: plain)
        XCTAssertFalse(system.isActive)
        XCTAssertEqual(asked, 0)
    }

    func testAnUntrustedRunStartsNothingAndADeclineIsNotStored() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (system, trust) = makeSystem(in: directory)
        defer { system.stop() }
        let root = directory.appendingPathComponent("pkg", isDirectory: true)
        try writePackage(Self.manifestSource, in: root)
        let sentinel = directory.appendingPathComponent("ran")
        system.launchEnvironment = try installSwift(script: "touch \"\(sentinel.path)\"", in: directory)
        system.trustPrompt = { _ in false }
        system.projectDidChange(root: root)

        system.runTasks(["build"])
        let declined = await waitUntil { self.consoleText(system).contains("Not run") && !system.isBusy }
        XCTAssertTrue(declined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertNil(trust.decision(for: root))
    }

    func testBuildErrorsReachTheProblemsHandlerAndAGoodBuildClearsThem() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (system, trust) = makeSystem(in: directory)
        defer { system.stop() }
        let root = directory.appendingPathComponent("pkg", isDirectory: true)
        try writePackage(Self.manifestSource, in: root)
        let file = root.appendingPathComponent("Sources/DemoKit/A.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let a = missing\n".write(to: file, atomically: false, encoding: .utf8)
        trust.setTrusted(true, for: root)
        let script = """
        if [ "$1" = package ]; then exit 1; fi
        echo "\(file.path):1:9: error: cannot find 'missing' in scope" >&2
        exit 1
        """
        system.launchEnvironment = try installSwift(script: script, in: directory)
        var reports: [[URL: [Diagnostic]]] = []
        system.onBuildDiagnostics = { reports.append($0) }
        system.projectDidChange(root: root)

        system.build()
        let failed = await waitUntil { !system.isBusy && !reports.isEmpty }
        XCTAssertTrue(failed, consoleText(system))
        let diagnostics = try XCTUnwrap(reports.last?[file.standardizedFileURL])
        XCTAssertEqual(diagnostics.first?.severity, .error)
        XCTAssertEqual(diagnostics.first?.message, "cannot find 'missing' in scope")
        XCTAssertEqual(diagnostics.first?.range.start.column, 8)
        XCTAssertTrue(consoleText(system).contains("swift exited 1"))

        system.launchEnvironment = try installSwift(script: "echo Build complete", in: directory)
        system.build()
        let cleared = await waitUntil { !system.isBusy && reports.count >= 2 }
        XCTAssertTrue(cleared)
        XCTAssertTrue(reports.last?.isEmpty == true)
    }

    func testATrustedFolderIsEvaluatedForTheExactModel() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (system, trust) = makeSystem(in: directory)
        defer { system.stop() }
        let root = directory.appendingPathComponent("pkg", isDirectory: true)
        try writePackage(Self.manifestSource, in: root)
        trust.setTrusted(true, for: root)
        let json = #"{"name":"Dyn","targets":[{"name":"Generated","type":"regular","dependencies":[]},{"name":"gen","type":"executable","dependencies":[]}],"products":[],"dependencies":[]}"#
        system.launchEnvironment = try installSwift(
            script: "if [ \"$1\" = package ] && [ \"$2\" = dump-package ]; then echo '\(json)'; fi", in: directory
        )
        var latest: IDESwiftPMManifest?
        system.onModelChanged = { manifest, _ in latest = manifest }
        system.projectDidChange(root: root)
        XCTAssertEqual(system.manifest?.isExact, false, "the syntactic model first")

        let refined = await waitUntil { system.manifest?.isExact == true }
        XCTAssertTrue(refined)
        XCTAssertEqual(system.manifest?.targets.map(\.name), ["Generated", "gen"])
        XCTAssertEqual(latest?.name, "Dyn")
        XCTAssertEqual(system.tasks.map(\.path), ["build", "run:gen", "resolve", "update", "clean"])
    }

    func testCancellingStopsTheCommand() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (system, trust) = makeSystem(in: directory)
        defer { system.stop() }
        let root = directory.appendingPathComponent("pkg", isDirectory: true)
        try writePackage(Self.manifestSource, in: root)
        trust.setTrusted(true, for: root)
        system.launchEnvironment = try installSwift(
            script: "if [ \"$1\" = package ]; then exit 1; fi\necho started\nsleep 30\necho finished", in: directory
        )
        system.projectDidChange(root: root)
        system.runTasks(["build"])
        let started = await waitUntil { self.consoleText(system).contains("started") && system.isBusy }
        XCTAssertTrue(started, consoleText(system))
        system.cancelTasks()
        let stopped = await waitUntil { !system.isBusy }
        XCTAssertTrue(stopped)
        XCTAssertTrue(consoleText(system).contains("Cancelled"))
        XCTAssertFalse(consoleText(system).contains("finished"))
    }

    func testAFolderWithAPackageJSONKeepsNpmFirst() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (swiftPM, _) = makeSystem(in: directory)
        let npm = IDENpmProjectSystem(
            status: IDEProjectStatus(),
            trustStore: GradleTrustStore(storeURL: directory.appendingPathComponent("npm-trust.json")),
            scriptDefaults: UserDefaults(suiteName: "umbra.swiftpm.tests.\(UUID().uuidString)")!
        )
        let systems = IDEProjectSystems([npm, swiftPM])
        defer { systems.stop() }
        let root = directory.appendingPathComponent("both", isDirectory: true)
        try writePackage(Self.manifestSource, in: root)
        try #"{"scripts":{"start":"node x"}}"#.write(
            to: root.appendingPathComponent("package.json"), atomically: false, encoding: .utf8
        )
        systems.projectDidChange(root: root)
        XCTAssertEqual(systems.active?.id, "npm")
        XCTAssertEqual(systems.activeSystems.map(\.id), ["npm", "swiftpm"])
    }
}
