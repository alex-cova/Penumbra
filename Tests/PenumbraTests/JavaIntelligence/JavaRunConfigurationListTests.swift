import XCTest
@testable import JavaIntelligence

/// Named and multiple run configurations, and the classpath launch target.
final class JavaRunConfigurationListTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")

    // MARK: - Classpath launches

    func testClasspathLaunchQuotesTheClasspathAndKeepsSettings() {
        let configuration = JavaRunConfiguration(
            target: .classpathMain(className: "app.Main", sourceFile: "/proj/app/src/main/java/app/Main.java"),
            programArguments: "--port 80",
            vmArguments: "-Xmx1g",
            environment: ["MODE": "dev"]
        )
        let classpath = [
            URL(fileURLWithPath: "/My Proj/app/build/classes/java/main"),
            URL(fileURLWithPath: "/My Proj/lib/it's.jar")
        ]
        let command = JavaLaunchCommand.make(
            configuration: configuration, projectRoot: root, gradleWrapperExists: false, runtimeClasspath: classpath
        )
        XCTAssertEqual(
            command?.shellCommand,
            "MODE='dev' java -Xmx1g -cp '/My Proj/app/build/classes/java/main:/My Proj/lib/it'\\''s.jar' app.Main --port 80"
        )
    }

    func testClasspathLaunchNeedsAClasspathAndAPlainClassName() {
        let good = JavaRunConfiguration(target: .classpathMain(className: "a.B", sourceFile: "/x/B.java"))
        let classpath = [URL(fileURLWithPath: "/x/classes")]
        XCTAssertNil(JavaLaunchCommand.make(configuration: good, projectRoot: root, gradleWrapperExists: false, runtimeClasspath: nil))
        XCTAssertNil(JavaLaunchCommand.make(configuration: good, projectRoot: root, gradleWrapperExists: false, runtimeClasspath: []))
        for bad in ["a.B; rm -rf ~", "a..B", "1A", "a.B$(x)", ""] {
            let evil = JavaRunConfiguration(target: .classpathMain(className: bad, sourceFile: "/x/B.java"))
            XCTAssertNil(
                JavaLaunchCommand.make(configuration: evil, projectRoot: root, gradleWrapperExists: false, runtimeClasspath: classpath),
                bad
            )
        }
        XCTAssertNotNil(JavaLaunchCommand.make(configuration: good, projectRoot: root, gradleWrapperExists: false, runtimeClasspath: classpath))
    }

    func testMakeClasspathLaunchDerivesTheClassNameFromThePackage() throws {
        let file = URL(fileURLWithPath: "/Users/dev/demo/app/src/main/java/app/Main.java")
        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("runtime-classpath"))
        let source = "/* header */\n// package fake;\npackage  app . sub ;\nclass Main {}\n"
        XCTAssertEqual(
            JavaRunConfiguration.makeClasspathLaunch(file: file, source: source, model: model)?.target,
            .classpathMain(className: "app.sub.Main", sourceFile: file.path)
        )
        XCTAssertEqual(
            JavaRunConfiguration.makeClasspathLaunch(file: file, source: "class Main {}", model: model)?.target,
            .classpathMain(className: "Main", sourceFile: file.path)
        )
        XCTAssertNil(JavaRunConfiguration.makeClasspathLaunch(file: URL(fileURLWithPath: "/elsewhere/A.java"), source: "", model: model))
        XCTAssertNil(JavaRunConfiguration.makeClasspathLaunch(file: file, source: "", model: nil))
    }

    func testMissingClassDirectoriesIgnoresJarsResourcesAndExistingDirectories() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cp-\(UUID().uuidString)")
        let built = base.appendingPathComponent("build/classes/java/main")
        try FileManager.default.createDirectory(at: built, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let missing = base.appendingPathComponent("lib/build/classes/java/main")
        let classpath = [
            built, missing,
            base.appendingPathComponent("build/resources/main"),
            base.appendingPathComponent("libs/x.jar")
        ]
        XCTAssertEqual(JavaRunConfiguration.missingClassDirectories(in: classpath), [missing])
    }

    func testVMArgumentsAreSupportedByEveryTargetButGradleRun() {
        XCTAssertTrue(JavaRunConfiguration(target: .classpathMain(className: "A", sourceFile: "/A.java")).supportsVMArguments)
        XCTAssertFalse(JavaRunConfiguration(target: .gradleRun(projectPath: ":")).supportsVMArguments)
        XCTAssertEqual(
            JavaRunConfiguration(target: .classpathMain(className: "a.b.Main", sourceFile: "/A.java")).displayName, "Main"
        )
    }

    // MARK: - Names and identity

    func testANameOverridesTheDefaultDisplayNameUnlessBlank() {
        var configuration = JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java"))
        XCTAssertEqual(configuration.displayName, "A.java")
        configuration.name = "  Server  "
        XCTAssertEqual(configuration.displayName, "Server")
        configuration.name = "   "
        XCTAssertEqual(configuration.displayName, "A.java")
    }

    func testInheritingSettingsKeepsTheIdAndNameOfTheSameTarget() {
        let previous = JavaRunConfiguration(name: "Mine", target: .singleFile(path: "/tmp/A.java"), programArguments: "x")
        let fresh = JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java")).inheritingSettings(from: previous)
        XCTAssertEqual(fresh.id, previous.id)
        XCTAssertEqual(fresh.name, "Mine")
        let other = JavaRunConfiguration(target: .singleFile(path: "/tmp/B.java")).inheritingSettings(from: previous)
        XCTAssertNotEqual(other.id, previous.id)
        XCTAssertNil(other.name)
    }

    func testAConfigurationSavedBeforeIdsAndNamesStillDecodes() throws {
        let json = #"{"target":{"singleFile":{"path":"/tmp/A.java"}},"programArguments":"a","vmArguments":"","environment":{}}"#
        let decoded = try JSONDecoder().decode(JavaRunConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.target, .singleFile(path: "/tmp/A.java"))
        XCTAssertEqual(decoded.programArguments, "a")
        XCTAssertNil(decoded.name)
        let roundTrip = try JSONDecoder().decode(JavaRunConfiguration.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip, decoded)
    }

    // MARK: - Store: several configurations per project

    private func makeStoreFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString)/run-configurations.json")
    }

    func testTheOldOneConfigurationPerProjectFileStillLoads() throws {
        let file = makeStoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = #"{"/proj":{"target":{"gradleRun":{"projectPath":":app"}},"programArguments":"go","vmArguments":"","environment":{}},"":{"target":{"singleFile":{"path":"/tmp/A.java"}},"programArguments":"","vmArguments":"-ea","environment":{}}}"#
        try Data(legacy.utf8).write(to: file)

        let store = JavaRunConfigurationStore(storeURL: file)
        XCTAssertEqual(store.last(forProject: root)?.target, .gradleRun(projectPath: ":app"))
        XCTAssertEqual(store.last(forProject: root)?.programArguments, "go")
        XCTAssertEqual(store.configurations(forProject: root).count, 1)
        XCTAssertEqual(store.last(forProject: nil)?.vmArguments, "-ea")

        // Saving rewrites it in the new format; the entry keeps its identity and other projects survive.
        let id = try XCTUnwrap(store.last(forProject: root)?.id)
        store.setLast(JavaRunConfiguration(id: id, name: "Renamed", target: .gradleRun(projectPath: ":app")), forProject: root)
        let reopened = JavaRunConfigurationStore(storeURL: file)
        XCTAssertEqual(reopened.configurations(forProject: root).map(\.name), ["Renamed"])
        XCTAssertNotNil(reopened.last(forProject: nil))
    }

    func testSeveralConfigurationsAreKeptWithASelectedOne() {
        let file = makeStoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JavaRunConfigurationStore(storeURL: file)
        let a = JavaRunConfiguration(name: "A", target: .gradleRun(projectPath: ":"))
        let b = JavaRunConfiguration(name: "B", target: .singleFile(path: "/tmp/B.java"))
        store.save(a, forProject: root)
        store.save(b, forProject: root)
        XCTAssertEqual(store.configurations(forProject: root).map(\.displayName), ["A", "B"])
        XCTAssertEqual(store.last(forProject: root)?.id, a.id, "saving alone selects only the first")

        store.select(b.id, forProject: root)
        XCTAssertEqual(store.last(forProject: root)?.id, b.id)
        store.select(UUID(), forProject: root)
        XCTAssertEqual(store.last(forProject: root)?.id, b.id, "an unknown id is ignored")

        var edited = a
        edited.programArguments = "x"
        store.setLast(edited, forProject: root)
        XCTAssertEqual(store.configurations(forProject: root).map(\.programArguments), ["x", ""], "an edit keeps its place")
        XCTAssertEqual(store.last(forProject: root)?.id, a.id)

        let reopened = JavaRunConfigurationStore(storeURL: file)
        XCTAssertEqual(reopened.configurations(forProject: root).map(\.displayName), ["A", "B"])
        XCTAssertEqual(reopened.last(forProject: root)?.id, a.id)
    }

    func testDuplicateAndDelete() throws {
        let file = makeStoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JavaRunConfigurationStore(storeURL: file)
        let a = JavaRunConfiguration(name: "Server", target: .gradleRun(projectPath: ":app"), programArguments: "go")
        store.setLast(a, forProject: root)

        let copy = try XCTUnwrap(store.duplicate(a.id, forProject: root))
        XCTAssertNotEqual(copy.id, a.id)
        XCTAssertEqual(copy.displayName, "Server copy")
        XCTAssertEqual(copy.programArguments, "go")
        XCTAssertEqual(store.last(forProject: root)?.id, copy.id, "the copy is selected")
        XCTAssertNil(store.duplicate(UUID(), forProject: root))

        store.delete(copy.id, forProject: root)
        XCTAssertEqual(store.configurations(forProject: root).map(\.id), [a.id])
        XCTAssertEqual(store.last(forProject: root)?.id, a.id, "deleting the selected one selects what is left")
        store.delete(a.id, forProject: root)
        XCTAssertNil(store.last(forProject: root))
        XCTAssertTrue(JavaRunConfigurationStore(storeURL: file).configurations(forProject: root).isEmpty)
    }

    func testOnlyTheNewestUnnamedConfigurationsAreKeptAndNamedOnesNever() {
        let file = makeStoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JavaRunConfigurationStore(storeURL: file)
        let named = JavaRunConfiguration(name: "Keep", target: .singleFile(path: "/tmp/Keep.java"))
        store.setLast(named, forProject: root)
        let cap = JavaRunConfigurationStore.maxUnnamedConfigurations
        for index in 0..<(cap + 5) {
            store.setLast(JavaRunConfiguration(target: .singleFile(path: "/tmp/F\(index).java")), forProject: root)
        }
        let all = store.configurations(forProject: root)
        XCTAssertEqual(all.filter { $0.name == nil }.count, cap)
        XCTAssertTrue(all.contains { $0.id == named.id })
        XCTAssertEqual(all.last?.target, .singleFile(path: "/tmp/F\(cap + 4).java"), "the newest is kept and selected")
        XCTAssertEqual(store.last(forProject: root)?.id, all.last?.id)
        XCTAssertFalse(all.contains { $0.target == .singleFile(path: "/tmp/F0.java") })
    }
}
