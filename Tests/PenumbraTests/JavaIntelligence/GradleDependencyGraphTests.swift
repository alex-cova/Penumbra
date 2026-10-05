import XCTest
@testable import JavaIntelligence

final class GradleDependencyGraphTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradle-deps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Decoding

    private let sampleJSON = """
    {
      "formatVersion": 1, "gradleVersion": "8.10", "project": ":app", "configuration": "runtimeClasspath",
      "rootKey": "project::app",
      "components": [
        {"key": "project::app", "kind": "project", "name": "app", "projectPath": ":app"},
        {"key": "com.google.guava:guava", "kind": "module", "group": "com.google.guava", "name": "guava", "version": "33.0.0-jre", "conflictResolved": true},
        {"key": "org.checkerframework:checker-qual", "kind": "module", "group": "org.checkerframework", "name": "checker-qual", "version": "3.42.0"},
        {"key": "unresolved:org.example:gone:1.0", "kind": "unresolved", "name": "org.example:gone:1.0", "message": "Could not resolve"}
      ],
      "edges": [
        {"from": "project::app", "to": "com.google.guava:guava", "requestedVersion": "31.0", "constraint": false},
        {"from": "com.google.guava:guava", "to": "org.checkerframework:checker-qual", "constraint": true},
        {"from": "project::app", "to": "unresolved:org.example:gone:1.0", "constraint": false}
      ]
    }
    """

    func testDecodesScriptOutput() throws {
        let graph = try JSONDecoder().decode(GradleDependencyGraph.self, from: Data(sampleJSON.utf8))
        XCTAssertEqual(graph.project, ":app")
        XCTAssertEqual(graph.rootKey, "project::app")
        XCTAssertEqual(graph.components.count, 4)
        let guava = try XCTUnwrap(graph.components.first { $0.name == "guava" })
        XCTAssertEqual(guava.coordinate, "com.google.guava:guava")
        XCTAssertEqual(guava.version, "33.0.0-jre")
        XCTAssertTrue(guava.conflictResolved)
        XCTAssertEqual(graph.components.first { $0.kind == .unresolved }?.message, "Could not resolve")
        XCTAssertEqual(graph.edges.first { $0.to == "com.google.guava:guava" }?.requestedVersion, "31.0")
        XCTAssertTrue(graph.edges.contains { $0.constraint })
        XCTAssertNil(graph.error)
    }

    func testDecodingToleratesMissingOptionalFields() throws {
        let json = #"{"components":[{"key":"a:b","name":"b"}],"edges":[{"from":"a:b","to":"a:b"}]}"#
        let graph = try JSONDecoder().decode(GradleDependencyGraph.self, from: Data(json.utf8))
        XCTAssertEqual(graph.components.first?.kind, .module)
        XCTAssertEqual(graph.edges.first?.constraint, false)
        XCTAssertEqual(graph.project, ":")
    }

    // MARK: - Limiting

    func testLimitKeepsTheComponentsNearestTheRoot() {
        var components = [GradleDependencyGraph.Component(key: "root", kind: .project, name: "root", projectPath: ":")]
        var edges: [GradleDependencyGraph.Edge] = []
        for number in 0..<5 {
            components.append(.init(key: "g:near\(number)", kind: .module, group: "g", name: "near\(number)", version: "1"))
            edges.append(.init(from: "root", to: "g:near\(number)"))
            components.append(.init(key: "g:far\(number)", kind: .module, group: "g", name: "far\(number)", version: "1"))
            edges.append(.init(from: "g:near\(number)", to: "g:far\(number)"))
        }
        let graph = GradleDependencyGraph(rootKey: "root", components: components, edges: edges)
        let limited = graph.limited(to: 6)
        XCTAssertEqual(limited.components.count, 6)
        XCTAssertEqual(limited.omittedCount, 5)
        XCTAssertTrue(limited.truncated)
        XCTAssertEqual(Set(limited.components.map(\.key)).filter { $0.contains("near") }.count, 5)
        XCTAssertTrue(limited.edges.allSatisfy { edge in
            limited.components.contains { $0.key == edge.from } && limited.components.contains { $0.key == edge.to }
        })
    }

    func testLimitLeavesASmallGraphAlone() throws {
        let graph = try JSONDecoder().decode(GradleDependencyGraph.self, from: Data(sampleJSON.utf8))
        XCTAssertEqual(graph.limited(to: 800), graph)
        XCTAssertFalse(graph.limited().truncated)
    }

    // MARK: - Module graph

    func testModuleGraphComesFromTheSyncedModelWithoutRunningGradle() {
        func subproject(_ path: String, compile: [String] = [], runtime: [String] = []) -> JavaGradleProjectModel.Subproject {
            .init(
                path: path, directory: scratch.appendingPathComponent(path == ":" ? "root" : String(path.dropFirst())),
                sourceSets: [
                    .init(
                        name: "main",
                        projectDependencies: compile.map { .init(projectPath: $0, sourceSetName: "main") },
                        runtimeProjectDependencies: (compile + runtime).map { .init(projectPath: $0, sourceSetName: "main") }
                    ),
                    .init(name: "test", projectDependencies: [.init(projectPath: ":only-test", sourceSetName: "main")])
                ]
            )
        }
        let model = JavaGradleProjectModel(formatVersion: 5, gradleVersion: "8.10", subprojects: [
            subproject(":"),
            subproject(":app", compile: [":lib"], runtime: [":plugin"]),
            subproject(":lib", compile: [":app", ":lib"]),
            subproject(":plugin"),
            subproject(":only-test")
        ])
        let graph = GradleDependencyGraph.moduleGraph(from: model)

        XCTAssertEqual(graph.components.map(\.projectPath), [":", ":app", ":lib", ":only-test", ":plugin"])
        XCTAssertEqual(graph.rootKey, "project::")
        XCTAssertEqual(graph.components.first { $0.projectPath == ":app" }?.name, "app")

        let pairs = Set(graph.edges.map { "\($0.from)>\($0.to)" })
        XCTAssertTrue(pairs.contains("project::app>project::lib"))
        XCTAssertTrue(pairs.contains("project::app>project::plugin"))
        XCTAssertFalse(pairs.contains { $0.hasSuffix("only-test") }, "Test source sets do not count")
        XCTAssertFalse(pairs.contains("project::lib>project::lib"), "A project does not depend on itself")
        XCTAssertEqual(graph.edges.first { $0.to == "project::plugin" }?.runtimeOnly, true)
        XCTAssertEqual(graph.edges.first { $0.to == "project::lib" && $0.from == "project::app" }?.runtimeOnly, false)
    }

    // MARK: - Extractor

    func testExtractorRunsTheScriptForTheProjectAndDecodesItsOutput() async throws {
        let launcher = ScriptedLauncher(json: sampleJSON)
        let store = GradleTrustStore(storeURL: scratch.appendingPathComponent("trust.json"))
        store.setTrusted(true, for: scratch)
        let runner = GradleCommandRunner(
            trustStore: store, launcher: launcher,
            resolver: GradleExecutableResolver(processRunner: StubProcessRunner(output: "/usr/bin/gradle"))
        )
        let graph = try await GradleDependencyGraphExtractor(runner: runner).extract(
            projectDirectory: scratch, projectPath: ":app", configuration: "compileClasspath", javaHome: nil
        )
        XCTAssertEqual(graph.components.count, 4)

        let last = await launcher.lastCommand
        let command = try XCTUnwrap(last)
        XCTAssertTrue(command.arguments.contains(":app:umbraDependencyGraph"))
        XCTAssertTrue(command.arguments.contains("--init-script"))
        XCTAssertTrue(command.arguments.contains("-PumbraDependencyConfiguration=compileClasspath"))
        XCTAssertTrue(command.arguments.contains { $0.hasPrefix("-PumbraDependencyOutput=") })
        XCTAssertTrue(command.arguments.contains("--no-configuration-cache"))
    }

    func testTaskPathForRootAndNestedProjects() {
        XCTAssertEqual(GradleDependencyGraphExtractor.taskPath(forProject: ":"), ":umbraDependencyGraph")
        XCTAssertEqual(GradleDependencyGraphExtractor.taskPath(forProject: ":lib:core"), ":lib:core:umbraDependencyGraph")
    }

    func testExtractorReportsAMissingConfiguration() async throws {
        let json = #"{"project":":x","configuration":"nope","error":"Project :x has no resolvable configuration named nope"}"#
        let launcher = ScriptedLauncher(json: json)
        let store = GradleTrustStore(storeURL: scratch.appendingPathComponent("trust.json"))
        store.setTrusted(true, for: scratch)
        let runner = GradleCommandRunner(
            trustStore: store, launcher: launcher,
            resolver: GradleExecutableResolver(processRunner: StubProcessRunner(output: "/usr/bin/gradle"))
        )
        do {
            _ = try await GradleDependencyGraphExtractor(runner: runner).extract(projectDirectory: scratch, javaHome: nil)
            XCTFail("expected an error")
        } catch GradleDependencyGraphError.unavailable(let message) {
            XCTAssertTrue(message.contains("nope"))
        }
    }

    func testExtractorRefusesAnUntrustedProject() async throws {
        let store = GradleTrustStore(storeURL: scratch.appendingPathComponent("trust.json"))
        let runner = GradleCommandRunner(trustStore: store, launcher: ScriptedLauncher(json: sampleJSON))
        do {
            _ = try await GradleDependencyGraphExtractor(runner: runner).extract(projectDirectory: scratch, javaHome: nil)
            XCTFail("expected an error")
        } catch GradleCommandError.untrusted {
        }
    }

    func testScriptHasNoUnbalancedBraces() {
        let script = GradleDependencyGraphScript.source
        XCTAssertEqual(script.filter { $0 == "{" }.count, script.filter { $0 == "}" }.count)
        XCTAssertTrue(script.contains("formatVersion: \(GradleDependencyGraph.formatVersion)"))
    }

    // MARK: - Real Gradle (opt-in: needs gradle on PATH and a JDK)

    func testRealGradleResolvesProjectDependencies() async throws {
        guard let jdk = TestJDK.discovered else { throw XCTSkip("No JDK found on this machine") }
        guard let gradle = try? SystemProcessRunner().run(executable: "/bin/zsh", arguments: ["-lc", "command -v gradle"]),
              !gradle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("No gradle found on PATH")
        }
        let root = scratch.appendingPathComponent("project", isDirectory: true)
        let fileManager = FileManager.default
        for module in ["app", "lib"] {
            try fileManager.createDirectory(at: root.appendingPathComponent("\(module)/src/main/java"), withIntermediateDirectories: true)
        }
        try "rootProject.name = 'deps-it'\ninclude 'app', 'lib'\n"
            .write(to: root.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8)
        try "plugins { id 'java-library' }\n"
            .write(to: root.appendingPathComponent("lib/build.gradle"), atomically: true, encoding: .utf8)
        try "plugins { id 'java' }\ndependencies { implementation project(':lib') }\n"
            .write(to: root.appendingPathComponent("app/build.gradle"), atomically: true, encoding: .utf8)

        let store = GradleTrustStore(storeURL: scratch.appendingPathComponent("trust.json"))
        store.setTrusted(true, for: root)
        let extractor = GradleDependencyGraphExtractor(runner: GradleCommandRunner(trustStore: store))
        let graph = try await extractor.extract(
            projectDirectory: root, projectPath: ":app", javaHome: jdk.home, timeout: .seconds(300)
        )
        XCTAssertEqual(graph.rootKey, "project::app")
        XCTAssertTrue(graph.components.contains { $0.key == "project::lib" && $0.kind == .project })
        XCTAssertTrue(graph.edges.contains { $0.from == "project::app" && $0.to == "project::lib" })
    }
}

private struct StubProcessRunner: ProcessRunning {
    let output: String
    func run(executable: String, arguments: [String], currentDirectory: URL?, environment: [String: String]?) throws -> String {
        output
    }
}

/// Stands in for Gradle: writes `json` where `-PumbraDependencyOutput=` points, like the init script does.
private actor ScriptedLauncher: GradleProcessLaunching {
    private let json: String
    private(set) var lastCommand: GradleCommand?

    init(json: String) {
        self.json = json
    }

    func launch(_ command: GradleCommand, timeout: Duration, output: GradleOutputHandler?) async throws -> GradleCommandResult {
        lastCommand = command
        if let argument = command.arguments.first(where: { $0.hasPrefix("-PumbraDependencyOutput=") }) {
            let path = String(argument.dropFirst("-PumbraDependencyOutput=".count))
            try json.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return GradleCommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}
