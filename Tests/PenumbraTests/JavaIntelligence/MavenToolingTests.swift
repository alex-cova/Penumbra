import XCTest
@testable import JavaIntelligence

final class MavenToolingTests: XCTestCase {
    func testDownloadPOMListsMissingArtifactsWithExclusions() {
        let missing = [
            MavenDependency(groupId: "com.example", artifactId: "lib", version: "1.0"),
            MavenDependency(groupId: "com.example", artifactId: "parent", version: "2", type: "pom"),
        ]
        let repositories = [MavenRepository(id: "central", url: "https://repo.example/maven", releases: true, snapshots: false)]
        let xml = MavenDependencyDownload.document(dependencies: missing, repositories: repositories)
        XCTAssertTrue(xml.contains("<artifactId>lib</artifactId>"))
        XCTAssertTrue(xml.contains("<type>pom</type>"))
        XCTAssertTrue(xml.contains("<groupId>*</groupId>"))
        XCTAssertTrue(xml.contains("<artifactId>*</artifactId>"))
        XCTAssertTrue(xml.contains("https://repo.example/maven"))
        XCTAssertTrue(xml.contains("<snapshots><enabled>false</enabled></snapshots>"))
        XCTAssertFalse(xml.contains("<plugins>"))
    }

    func testDownloadSourcesUsesTheSourcesClassifier() {
        let module = MavenModule(
            path: ":", directory: URL(fileURLWithPath: "/work"), groupId: "com.example", artifactId: "app", version: "1",
            dependencyTree: [
                MavenDependencyNode(groupId: "com.example", artifactId: "lib", version: "1", scope: "compile"),
                MavenDependencyNode(
                    groupId: "com.example", artifactId: "api", version: "1", scope: "compile", projectPath: ":api"
                )
            ],
            outputDirectory: URL(fileURLWithPath: "/work/target/classes"),
            testOutputDirectory: URL(fileURLWithPath: "/work/target/test-classes")
        )
        let model = MavenProjectModel(modules: [module], profiles: [], repositories: [], missing: [], unresolved: [])
        let artifacts = MavenDependencyDownload.artifacts(in: model, sources: true)
        XCTAssertEqual(artifacts.map(\.artifactId), ["lib"])
        XCTAssertEqual(artifacts.first?.classifier, "sources")
    }

    func testProblemMatcherMapsCompilerLinesAndSurefire() throws {
        let stdout = """
        [ERROR] /work/src/main/java/App.java:[12,5] cannot find symbol
        [WARNING] /work/src/main/java/App.java:[4,8] unused
        [ERROR] Tests run: 3, Failures: 1, Errors: 1, Skipped: 0
        [ERROR] Failed to execute goal org.apache.maven.plugins:maven-surefire-plugin:3.2.5:test
        """
        let matched = MavenProblemMatcher.match(stdout: stdout, stderr: "", baseDirectory: URL(fileURLWithPath: "/work"))
        let diagnostics = try XCTUnwrap(matched.diagnostics[URL(fileURLWithPath: "/work/src/main/java/App.java")])
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertTrue(matched.problems.contains { $0.kind == .testFailures && $0.message == "2 tests failed" })
        XCTAssertTrue(matched.problems.contains { $0.message.contains("Failed to execute goal") })
    }

    func testTestCommandFiltersAndDebug() throws {
        let directory = URL(fileURLWithPath: "/work/services/api", isDirectory: true)
        let module = MavenModule(
            path: ":services:api", directory: directory, groupId: "com.example", artifactId: "api", version: "1",
            outputDirectory: directory.appendingPathComponent("target/classes"),
            testOutputDirectory: directory.appendingPathComponent("target/test-classes")
        )
        let model = MavenProjectModel(modules: [module], profiles: [], repositories: [], missing: [], unresolved: [])
        let method = JavaTestMethod(
            className: "com.example.ApiTest", methodName: "adds", displayName: "adds",
            sourceFile: directory.appendingPathComponent("src/test/java/ApiTest.java"),
            line: 10, column: 4, framework: .junit5
        )
        let one = try XCTUnwrap(MavenTestRunner.command(
            scope: .testMethod(method, taskPath: ":services:api:test"), model: model
        ))
        XCTAssertEqual(one.goals, ["test"])
        XCTAssertEqual(one.arguments, [
            "-pl", "com.example:api", "-am",
            "-Dsurefire.failIfNoSpecifiedTests=false",
            "-Dtest=com.example.ApiTest#adds"
        ])
        XCTAssertEqual(one.reportDirectories.first?.lastPathComponent, "surefire-reports")

        let several = try XCTUnwrap(MavenTestRunner.command(
            scope: .tests(taskPath: ":services:api:test", filters: ["com.example.ApiTest.adds", "com.example.ApiTest.removes", "com.example.OtherTest"]),
            model: model, debug: true
        ))
        XCTAssertTrue(several.arguments.contains("-Dtest=com.example.ApiTest#adds+removes,com.example.OtherTest"))
        XCTAssertTrue(several.arguments.contains(MavenTestRunner.debugArgument))
        XCTAssertTrue(MavenTestRunner.debugArgument.contains("address=*:5005"))
    }

    func testCoverageArguments() {
        let directory = URL(fileURLWithPath: "/work", isDirectory: true)
        var module = MavenModule(
            path: ":", directory: directory, groupId: "com.example", artifactId: "app", version: "1",
            outputDirectory: directory.appendingPathComponent("target/classes"),
            testOutputDirectory: directory.appendingPathComponent("target/test-classes")
        )
        let agent = JavaCoverageCommand.agentArgument(
            agentJar: URL(fileURLWithPath: "/tools/jacoco.jar"),
            execFile: URL(fileURLWithPath: "/work/target/jacoco.exec")
        )
        let covered = MavenCoverageArguments.arguments(module: module, coverageAgent: agent)
        XCTAssertEqual(covered.arguments.count, 1)
        XCTAssertTrue(covered.arguments[0].hasPrefix("-DargLine=-javaagent:"))
        XCTAssertNil(covered.explanation)

        module.surefireArgLine = "-Xmx256m"
        let blocked = MavenCoverageArguments.arguments(module: module, coverageAgent: agent)
        XCTAssertTrue(blocked.arguments.isEmpty)
        XCTAssertEqual(blocked.explanation, MavenCoverageArguments.blockedExplanation)

        module.surefireArgLine = "@{argLine} -Xmx256m"
        let forwarded = MavenCoverageArguments.arguments(module: module, coverageAgent: agent)
        XCTAssertEqual(forwarded.arguments.count, 1)

        module.usesJacocoPrepareAgent = true
        let own = MavenCoverageArguments.arguments(module: module, coverageAgent: agent)
        XCTAssertTrue(own.arguments.isEmpty)
        XCTAssertEqual(own.moduleExecFile?.lastPathComponent, "jacoco.exec")
        XCTAssertNil(own.explanation)

        let profiled = MavenCoverageArguments.profiling(module: MavenModule(
            path: ":", directory: directory, groupId: "com.example", artifactId: "app", version: "1",
            outputDirectory: directory.appendingPathComponent("target/classes"),
            testOutputDirectory: directory.appendingPathComponent("target/test-classes")
        ), recordingFile: "/tmp/run.jfr")
        XCTAssertTrue(profiled.arguments.first?.contains("StartFlightRecording") == true)
    }

    func testBuildInputsIgnoreTargetAndKeepDotMvn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maven-inputs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mvn/wrapper"), withIntermediateDirectories: true)
        try "root".write(to: root.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        try "child".write(to: root.appendingPathComponent("src/pom.xml"), atomically: true, encoding: .utf8)
        try "skip".write(to: root.appendingPathComponent("target/pom.xml"), atomically: true, encoding: .utf8)
        try "-Drevision=1".write(to: root.appendingPathComponent(".mvn/maven.config"), atomically: true, encoding: .utf8)
        let paths = MavenBuildFiles.inputPaths(under: root)
        XCTAssertEqual(paths, [".mvn/maven.config", "pom.xml", "src/pom.xml"])
        let snapshot = GradleBuildFileSnapshot.capture(projectRoot: root, inputPaths: MavenBuildFiles.inputPaths(under:))
        XCTAssertFalse(snapshot.differs(relativePath: "pom.xml", projectRoot: root))
        try "changed".write(to: root.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        XCTAssertTrue(snapshot.differs(relativePath: "pom.xml", projectRoot: root))
        XCTAssertFalse(snapshot.differs(relativePath: "src/pom.xml", projectRoot: root))
    }

    func testRunnerRefusesAnUntrustedProject() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maven-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GradleTrustStore(storeURL: dir.appendingPathComponent("trust.json"))
        let launcher = MavenRecordingLauncher(result: GradleCommandResult(exitCode: 0, stdout: "", stderr: ""))
        let runner = MavenCommandRunner(
            trustStore: store, launcher: launcher,
            resolver: MavenExecutableResolver(processRunner: MavenFakeProcess(output: "/usr/bin/mvn"))
        )
        do {
            _ = try await runner.run(projectDirectory: dir, goals: ["test"])
            XCTFail("expected the trust gate")
        } catch GradleCommandError.untrusted {
        }
        let count = await launcher.launchCount
        XCTAssertEqual(count, 0)
    }

    func testRunnerPrefersTheWrapperAndPassesBatchFlags() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maven-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".mvn"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wrapper = dir.appendingPathComponent("mvnw")
        try "#!/bin/sh\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wrapper.path)
        let store = GradleTrustStore(storeURL: dir.appendingPathComponent("trust.json"))
        store.setTrusted(true, for: dir)
        let launcher = MavenRecordingLauncher(result: GradleCommandResult(exitCode: 0, stdout: "ok", stderr: ""))
        let runner = MavenCommandRunner(trustStore: store, launcher: launcher, resolver: MavenExecutableResolver())
        let settings = dir.appendingPathComponent("settings.xml")
        let result = try await runner.run(
            projectDirectory: dir, goals: ["test"], arguments: ["-DskipTests"],
            javaHome: URL(fileURLWithPath: "/jdks/21"), settingsFile: settings, offline: true
        )
        XCTAssertEqual(result.stdout, "ok")
        let recorded = await launcher.lastCommand
        let command = try XCTUnwrap(recorded)
        XCTAssertEqual(command.executable, URL(fileURLWithPath: "/bin/sh"))
        XCTAssertEqual(command.arguments.prefix(4), [wrapper.path, "-B", "-ntp", "-s"])
        XCTAssertTrue(command.arguments.contains(settings.path))
        XCTAssertTrue(command.arguments.contains("-o"))
        XCTAssertEqual(command.arguments.suffix(2), ["test", "-DskipTests"])
        XCTAssertEqual(command.environment["JAVA_HOME"], "/jdks/21")
    }
}

private struct MavenFakeProcess: ProcessRunning {
    let output: String
    func run(executable: String, arguments: [String], currentDirectory: URL?, environment: [String: String]?) throws -> String {
        output
    }
}

private actor MavenRecordingLauncher: GradleProcessLaunching {
    private let result: GradleCommandResult
    private(set) var lastCommand: GradleCommand?
    private(set) var launchCount = 0

    init(result: GradleCommandResult) { self.result = result }

    func launch(_ command: GradleCommand, timeout: Duration, output: GradleOutputHandler?) async throws -> GradleCommandResult {
        lastCommand = command
        launchCount += 1
        return result
    }
}
