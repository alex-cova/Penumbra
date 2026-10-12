import EditorIntelligence
import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// The Xcode project system: reading `project.xcproj` and `project.pbxproj` without running
/// anything, trust, a fake `xcodebuild` on PATH, and the compiler's problems. Projects come from
/// the New Project wizard's own templates, so the two are checked against each other.
@MainActor
final class IDEXcodeProjectSystemTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

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
            .appendingPathComponent("umbra-xcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSystem(in directory: URL) -> (IDEXcodeProjectSystem, GradleTrustStore) {
        let store = GradleTrustStore(storeURL: directory.appendingPathComponent("xcode-trust.json"))
        return (IDEXcodeProjectSystem(status: IDEProjectStatus(), trustStore: store), store)
    }

    /// Creates the macOS app template at `<directory>/<name>` and returns its root.
    private func makeApp(named name: String = "My App", in directory: URL) throws -> URL {
        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.xcode.macos-app"))
        let options = IDENewProjectOptions(name: name, parentDirectory: directory)
        return try IDEProjectWriter.create(template, options: options)
    }

    /// An executable named `xcodebuild` first on PATH; `/bin` and `/usr/bin` stay so `sleep` resolves.
    private func installXcodebuild(script: String, in directory: URL) throws -> [String: String] {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("xcodebuild")
        try "#!/bin/sh\n\(script)\n".write(to: tool, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return ["PATH": bin.path + ":/bin:/usr/bin"]
    }

    private func consoleText(_ system: IDEXcodeProjectSystem) -> String {
        system.console.lines.map(\.text).joined(separator: "\n")
    }

    // MARK: Model

    func testAGeneratedProjectIsReadWithoutTrustOrAProcess() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try makeApp(in: directory)
        let (system, _) = makeSystem(in: directory)
        defer { system.stop() }
        system.launchEnvironment = ["PATH": "/nonexistent"]
        system.projectDidChange(root: root)

        XCTAssertTrue(system.isActive)
        XCTAssertEqual(system.syncState, .synced(modules: 1, dependencies: 0))
        XCTAssertEqual(system.model?.format, .xcproj)
        XCTAssertEqual(system.model?.targets.map(\.name), ["My_App"])
        XCTAssertEqual(system.model?.targets.first?.kind, .application)
        XCTAssertEqual(system.model?.configurations, ["Debug", "Release"])
        XCTAssertEqual(system.tasks.map(\.path), ["build", "build:My_App", "clean"])
        XCTAssertEqual(system.sourceRootPaths, [root.appendingPathComponent("My_App").standardizedFileURL.path])
        XCTAssertEqual(system.buildConfiguration, "Debug")
    }

    func testALegacyPbxprojIsReadAsAPropertyList() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Old", isDirectory: true)
        let project = root.appendingPathComponent("Old.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pbxproj = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            classes = {
            };
            objectVersion = 77;
            objects = {
                AAAA00000000000000000001 = {
                    isa = PBXNativeTarget;
                    name = Old;
                    productType = "com.apple.product-type.application";
                };
                AAAA00000000000000000002 = {
                    isa = PBXNativeTarget;
                    name = OldTests;
                    productType = "com.apple.product-type.bundle.unit-test";
                };
                AAAA00000000000000000003 = {
                    isa = PBXFileSystemSynchronizedRootGroup;
                    path = Old;
                    sourceTree = "<group>";
                };
                AAAA00000000000000000004 = {
                    isa = XCBuildConfiguration;
                    name = Debug;
                };
                AAAA00000000000000000005 = {
                    isa = XCBuildConfiguration;
                    name = Release;
                };
                AAAA00000000000000000006 = {
                    isa = XCRemoteSwiftPackageReference;
                    repositoryURL = "https://example.com/pkg";
                };
            };
            rootObject = AAAA00000000000000000007;
        }
        """
        try pbxproj.write(to: project.appendingPathComponent("project.pbxproj"), atomically: false, encoding: .utf8)
        let (system, _) = makeSystem(in: directory)
        defer { system.stop() }
        system.projectDidChange(root: root)

        XCTAssertEqual(system.model?.format, .pbxproj)
        XCTAssertEqual(system.model?.targets.map(\.name), ["Old", "OldTests"])
        XCTAssertEqual(system.model?.targets.map(\.kind), [.application, .test])
        XCTAssertEqual(system.model?.configurations, ["Debug", "Release"])
        XCTAssertEqual(system.syncState, .synced(modules: 2, dependencies: 1))
        XCTAssertEqual(system.sourceRootPaths, [root.appendingPathComponent("Old").standardizedFileURL.path])
    }

    func testTheProjectNamedLikeTheFolderWins() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Main", isDirectory: true)
        for name in ["Aardvark", "Main", "Zebra"] {
            let project = root.appendingPathComponent("\(name).xcodeproj", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try "{}".write(to: project.appendingPathComponent("project.xcproj"), atomically: false, encoding: .utf8)
        }
        XCTAssertEqual(IDEXcodeProjectModel.findProject(in: root)?.lastPathComponent, "Main.xcodeproj")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Main.xcodeproj"))
        XCTAssertEqual(IDEXcodeProjectModel.findProject(in: root)?.lastPathComponent, "Aardvark.xcodeproj")
    }

    func testAFolderWithoutAProjectIsNotDetected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (system, _) = makeSystem(in: directory)
        defer { system.stop() }
        system.projectDidChange(root: directory)
        XCTAssertFalse(system.isActive)
        XCTAssertEqual(system.syncState, .notDetected)
        XCTAssertTrue(system.tasks.isEmpty)
    }

    func testAnUnreadableProjectFailsTheSyncWithAReason() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Broken", isDirectory: true)
        let project = root.appendingPathComponent("Broken.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "this is not json".write(
            to: project.appendingPathComponent("project.xcproj"), atomically: false, encoding: .utf8
        )
        let (system, _) = makeSystem(in: directory)
        defer { system.stop() }
        system.projectDidChange(root: root)
        XCTAssertTrue(system.isActive)
        XCTAssertTrue(system.syncState.isFailed)
        XCTAssertNil(system.model)
    }

    // MARK: Trust and running

    func testAnUntrustedRunStartsNothingAndADeclineIsNotStored() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try makeApp(in: directory)
        let (system, trust) = makeSystem(in: directory)
        defer { system.stop() }
        let sentinel = directory.appendingPathComponent("ran")
        system.launchEnvironment = try installXcodebuild(script: "touch \"\(sentinel.path)\"", in: directory)
        system.trustPrompt = { _ in false }
        system.projectDidChange(root: root)

        system.runTasks(["build"])
        let declined = await waitUntil { self.consoleText(system).contains("Not run") && !system.isBusy }
        XCTAssertTrue(declined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertNil(trust.decision(for: root))
    }

    func testBuildPassesTheProjectTargetAndConfigurationAndReportsErrors() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try makeApp(in: directory)
        let (system, trust) = makeSystem(in: directory)
        defer { system.stop() }
        trust.setTrusted(true, for: root)
        let file = root.appendingPathComponent("My_App/ContentView.swift")
        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let script = """
        printf '%s\\n' "$@" > "\(argumentsFile.path)"
        echo "\(file.path):3:9: error: cannot find 'missing' in scope" >&2
        exit 65
        """
        system.launchEnvironment = try installXcodebuild(script: script, in: directory)
        var reports: [[URL: [Diagnostic]]] = []
        system.onBuildDiagnostics = { reports.append($0) }
        system.projectDidChange(root: root)

        system.runTasks(["build:My_App"])
        let finished = await waitUntil { !system.isBusy && !reports.isEmpty }
        XCTAssertTrue(finished, consoleText(system))

        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments, [
            "-project", root.appendingPathComponent("My App.xcodeproj").path,
            "-target", "My_App", "-configuration", "Debug", "build",
        ])
        let diagnostics = try XCTUnwrap(reports.last?[file.standardizedFileURL])
        XCTAssertEqual(diagnostics.first?.severity, .error)
        XCTAssertEqual(diagnostics.first?.message, "cannot find 'missing' in scope")
        XCTAssertTrue(consoleText(system).contains("xcodebuild exited 65"))
    }

    func testBuildAllUsesAllTargetsAndAnUnknownTaskIsIgnored() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try makeApp(in: directory)
        let (system, trust) = makeSystem(in: directory)
        defer { system.stop() }
        trust.setTrusted(true, for: root)
        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        system.launchEnvironment = try installXcodebuild(
            script: "printf '%s\\n' \"$@\" > \"\(argumentsFile.path)\"\necho '** BUILD SUCCEEDED **'", in: directory
        )
        system.projectDidChange(root: root)

        system.runTasks(["build:Nope"])
        XCTAssertFalse(system.isBusy)

        system.build()
        let done = await waitUntil { !system.isBusy && FileManager.default.fileExists(atPath: argumentsFile.path) }
        XCTAssertTrue(done)
        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
        XCTAssertTrue(arguments.contains("-alltargets"))
        XCTAssertFalse(arguments.contains("-target\n"))
    }

    func testCancellingStopsTheCommand() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try makeApp(in: directory)
        let (system, trust) = makeSystem(in: directory)
        defer { system.stop() }
        trust.setTrusted(true, for: root)
        system.launchEnvironment = try installXcodebuild(script: "sleep 30", in: directory)
        system.projectDidChange(root: root)

        system.build()
        let started = await waitUntil { system.isBusy }
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(200))
        system.cancelTasks()
        let stopped = await waitUntil(seconds: 5) { !system.isBusy }
        XCTAssertTrue(stopped)
        XCTAssertTrue(consoleText(system).contains("Cancelled"), consoleText(system))
    }

    // MARK: Changes on disk

    func testAChangeToTheProjectFileRaisesTheBannerAndAnUndoClearsIt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try makeApp(in: directory)
        let (system, _) = makeSystem(in: directory)
        defer { system.stop() }
        system.projectDidChange(root: root)
        let file = try XCTUnwrap(system.model).definitionFile
        let original = try Data(contentsOf: file)

        system.filesDidChange([file.path])
        XCTAssertFalse(system.hasConfigurationChanges, "same bytes raise nothing")

        try (original + Data("\n// edited\n".utf8)).write(to: file)
        system.filesDidChange([file.path])
        XCTAssertTrue(system.hasConfigurationChanges)

        try original.write(to: file)
        system.filesDidChange([file.path])
        XCTAssertFalse(system.hasConfigurationChanges)

        system.filesDidChange([root.appendingPathComponent("My_App/ContentView.swift").path])
        XCTAssertFalse(system.hasConfigurationChanges, "other files are not the project")
    }

    // MARK: Registry

    func testAFolderWithAPackageKeepsSwiftPMFirstAndBothStayActive() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try makeApp(in: directory)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "My_App", targets: [.executableTarget(name: "My_App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: false, encoding: .utf8)
        let (xcode, _) = makeSystem(in: directory)
        let swiftPM = IDESwiftPMProjectSystem(
            status: IDEProjectStatus(),
            trustStore: GradleTrustStore(storeURL: directory.appendingPathComponent("swiftpm-trust.json"))
        )
        let systems = IDEProjectSystems([swiftPM, xcode])
        defer { systems.stop() }
        systems.projectDidChange(root: root)

        XCTAssertEqual(systems.active?.id, "swiftpm")
        XCTAssertEqual(systems.activeSystems.map(\.id), ["swiftpm", "xcode"])
    }

    func testAnXcodeOnlyFolderIsOwnedByXcode() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try makeApp(in: directory)
        let (xcode, _) = makeSystem(in: directory)
        let systems = IDEProjectSystems([xcode])
        defer { systems.stop() }
        systems.projectDidChange(root: root)
        XCTAssertEqual(systems.active?.id, "xcode")
        XCTAssertEqual(
            systems.owner(of: root.appendingPathComponent("My_App/ContentView.swift"))?.path,
            root.standardizedFileURL.path
        )
    }
}
