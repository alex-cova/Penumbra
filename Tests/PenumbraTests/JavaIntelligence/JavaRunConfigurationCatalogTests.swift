import XCTest
@testable import JavaIntelligence

/// Temporary and saved configurations, templates, the project's own folder of shared ones, and the
/// catalog that merges the two.
final class JavaRunConfigurationCatalogTests: XCTestCase {
    private var directory: URL!
    private var project: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        project = directory.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCatalog() -> JavaRunConfigurationCatalog {
        JavaRunConfigurationCatalog(store: JavaRunConfigurationStore(storeURL: directory.appendingPathComponent("store.json")))
    }

    private func mainConfiguration(_ name: String? = nil, file: String = "A", shared: Bool = false) -> JavaRunConfiguration {
        JavaRunConfiguration(
            name: name,
            target: .classpathMain(className: "app.\(file)", sourceFile: project.appendingPathComponent("src/\(file).java").path),
            storeAsProjectFile: shared
        )
    }

    // MARK: - Model

    func testUnnamedConfigurationsAreTemporaryAndNamedOnesAreNot() {
        XCTAssertTrue(JavaRunConfiguration(target: .singleFile(path: "/a/A.java")).isTemporary)
        XCTAssertFalse(JavaRunConfiguration(name: "Mine", target: .singleFile(path: "/a/A.java")).isTemporary)
        XCTAssertFalse(JavaRunConfiguration(name: "  ", target: .singleFile(path: "/a/A.java"), isTemporary: false).isTemporary)
    }

    func testFilesSavedBeforeTheNewFieldsDecodeToTheirDefaults() throws {
        let unnamed = #"{"target":{"singleFile":{"path":"/tmp/A.java"}},"programArguments":"","vmArguments":"","environment":{}}"#
        let named = #"{"name":"Mine","target":{"singleFile":{"path":"/tmp/A.java"}}}"#
        let a = try JSONDecoder().decode(JavaRunConfiguration.self, from: Data(unnamed.utf8))
        let b = try JSONDecoder().decode(JavaRunConfiguration.self, from: Data(named.utf8))
        XCTAssertTrue(a.isTemporary)
        XCTAssertFalse(b.isTemporary)
        for configuration in [a, b] {
            XCTAssertTrue(configuration.buildBeforeRun)
            XCTAssertFalse(configuration.allowMultipleInstances)
            XCTAssertFalse(configuration.storeAsProjectFile)
            XCTAssertEqual(configuration.shortenCommandLine, .auto)
            XCTAssertTrue(configuration.beforeLaunch.isEmpty)
            XCTAssertNil(configuration.workingDirectory)
            XCTAssertNil(configuration.jdkHome)
        }
    }

    func testNewFieldsRoundTrip() throws {
        let other = UUID()
        let configuration = JavaRunConfiguration(
            name: "Full",
            target: .gradleTest(taskPath: ":app:test", filters: ["app.FooTest.testAdds"], sourceFile: "/p/FooTest.java"),
            folder: "Tests",
            workingDirectory: "/p/work",
            jdkHome: "/jdk",
            buildBeforeRun: false,
            allowMultipleInstances: true,
            beforeLaunch: [.gradleTasks([":app:classes"]), .runConfiguration(other)],
            shortenCommandLine: .argFile,
            redirectInputPath: "/p/in.txt"
        )
        let decoded = try JSONDecoder().decode(JavaRunConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
    }

    func testTestConfigurationsAreNamedAfterTheirFilters() {
        func name(_ filters: [String], task: String = ":app:test") -> String {
            JavaRunConfiguration(target: .gradleTest(taskPath: task, filters: filters, sourceFile: nil)).displayName
        }
        XCTAssertEqual(name([]), "All tests (:app)")
        XCTAssertEqual(name([], task: ":test"), "All tests (:)")
        XCTAssertEqual(name(["app.FooTest"]), "FooTest")
        XCTAssertEqual(name(["app.FooTest.testAdds"]), "FooTest.testAdds")
        XCTAssertEqual(name(["app.FooTest", "app.BarTest"]), "FooTest +1")
    }

    func testTestScopeAndKinds() {
        let all = JavaRunConfiguration(target: .gradleTest(taskPath: ":test", filters: [], sourceFile: nil))
        XCTAssertEqual(all.testScope, .allInModule(gradleTaskPath: ":test"))
        let some = JavaRunConfiguration(target: .gradleTest(taskPath: ":test", filters: ["a.B"], sourceFile: nil))
        XCTAssertEqual(some.testScope, .tests(taskPath: ":test", filters: ["a.B"]))
        XCTAssertNil(JavaRunConfiguration(target: .gradleRun(projectPath: ":")).testScope)
        XCTAssertEqual(all.kind, .junit)
        XCTAssertEqual(JavaRunConfiguration(target: .gradleRun(projectPath: ":")).kind, .gradle)
        XCTAssertEqual(JavaRunConfiguration(target: .singleFile(path: "/a.java")).kind, .javaFile)
        XCTAssertEqual(mainConfiguration().kind, .application)
    }

    func testWhichSettingsATargetTakes() {
        let main = mainConfiguration()
        XCTAssertTrue(main.supportsEnvironment && main.supportsWorkingDirectory && main.supportsBuildBeforeRun && main.supportsVMArguments)
        let file = JavaRunConfiguration(target: .singleFile(path: "/a.java"))
        XCTAssertTrue(file.supportsEnvironment)
        XCTAssertFalse(file.supportsBuildBeforeRun)
        for target in [JavaRunConfiguration.Target.gradleRun(projectPath: ":"), .gradleTest(taskPath: ":test", filters: [], sourceFile: nil)] {
            let gradle = JavaRunConfiguration(target: target)
            XCTAssertFalse(gradle.supportsEnvironment || gradle.supportsVMArguments || gradle.supportsWorkingDirectory)
        }
    }

    func testInheritingSettingsKeepsTheNewFields() {
        var previous = mainConfiguration("Mine")
        previous.workingDirectory = "/w"
        previous.buildBeforeRun = false
        previous.allowMultipleInstances = true
        previous.beforeLaunch = [.gradleTasks(["x"])]
        previous.storeAsProjectFile = true
        previous.folder = "Servers"
        let fresh = JavaRunConfiguration(target: previous.target)
        let inherited = fresh.inheritingSettings(from: previous)
        XCTAssertEqual(inherited.id, previous.id)
        XCTAssertEqual(inherited.workingDirectory, "/w")
        XCTAssertFalse(inherited.buildBeforeRun)
        XCTAssertTrue(inherited.allowMultipleInstances)
        XCTAssertEqual(inherited.beforeLaunch, previous.beforeLaunch)
        XCTAssertTrue(inherited.storeAsProjectFile)
        XCTAssertEqual(inherited.folder, "Servers")
        XCTAssertFalse(inherited.isTemporary)
    }

    func testAGradleTestCommandFiltersTheTask() {
        let configuration = JavaRunConfiguration(
            target: .gradleTest(taskPath: ":app:test", filters: ["app.FooTest", "app.Bar's"], sourceFile: nil)
        )
        let command = JavaLaunchCommand.make(configuration: configuration, projectRoot: project, gradleWrapperExists: true)
        XCTAssertEqual(
            command?.shellCommand,
            "cd '\(project.path)' && ./gradlew :app:test --tests 'app.FooTest' --tests 'app.Bar'\\''s'"
        )
    }

    // MARK: - Store: temporary cap, selection, templates

    func testTheTemporaryLimitIsConfigurableAndSparesSavedAndSelectedOnes() {
        let catalog = makeCatalog()
        let saved = mainConfiguration("Saved", file: "Saved")
        catalog.setLast(saved, forProject: project)
        for index in 0..<8 {
            catalog.setLast(mainConfiguration(file: "T\(index)"), forProject: project, temporaryLimit: 3)
        }
        let all = catalog.configurations(forProject: project)
        XCTAssertEqual(all.filter(\.isTemporary).count, 3)
        XCTAssertTrue(all.contains { $0.id == saved.id })
        XCTAssertEqual(catalog.last(forProject: project)?.target, mainConfiguration(file: "T7").target)
        XCTAssertFalse(all.contains { $0.target == mainConfiguration(file: "T0").target })
    }

    func testSaveConfigurationMakesATemporaryOneStay() {
        let catalog = makeCatalog()
        let temporary = mainConfiguration(file: "Keep")
        catalog.setLast(temporary, forProject: project)
        catalog.makePermanent(temporary.id, forProject: project)
        for index in 0..<10 {
            catalog.setLast(mainConfiguration(file: "T\(index)"), forProject: project, temporaryLimit: 2)
        }
        let kept = catalog.configurations(forProject: project).first { $0.id == temporary.id }
        XCTAssertNotNil(kept)
        XCTAssertEqual(kept?.isTemporary, false)
    }

    func testTemplatesStartNewConfigurationsAndSurviveARestart() {
        let storeURL = directory.appendingPathComponent("store.json")
        let store = JavaRunConfigurationStore(storeURL: storeURL)
        var template = store.template(for: .application, forProject: project)
        XCTAssertEqual(template.kind, .application)
        XCTAssertEqual(template.vmArguments, "")
        template.vmArguments = "-Xmx2g"
        template.environment = ["MODE": "dev"]
        store.setTemplate(template, forProject: project)

        let reopened = JavaRunConfigurationStore(storeURL: storeURL).template(for: .application, forProject: project)
        let made = reopened.instantiating(target: mainConfiguration(file: "B").target, name: "B")
        XCTAssertEqual(made.vmArguments, "-Xmx2g")
        XCTAssertEqual(made.environment, ["MODE": "dev"])
        XCTAssertNotEqual(made.id, reopened.id)
        XCTAssertEqual(made.name, "B")
        XCTAssertFalse(made.isTemporary)
        XCTAssertEqual(JavaRunConfigurationStore(storeURL: storeURL).template(for: .gradle, forProject: project).vmArguments, "")
    }

    // MARK: - Project folder

    func testASharedConfigurationIsAFileWithPathsRelativeToTheProject() throws {
        let folder = JavaProjectRunConfigurationFolder(root: project)
        var configuration = mainConfiguration("Server", shared: true)
        configuration.workingDirectory = project.appendingPathComponent("work").path
        configuration.redirectInputPath = "/elsewhere/input.txt"
        configuration.jdkHome = "/my/jdk"
        folder.save(configuration)

        let file = project.appendingPathComponent(".umbra/runConfigurations/Server.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"src/A.java\""), text)
        XCTAssertTrue(text.contains("\"work\""), text)
        XCTAssertTrue(text.contains("/elsewhere/input.txt"), "a path outside the project stays absolute")
        XCTAssertFalse(text.contains(project.path), "nothing machine-specific is committed")
        XCTAssertFalse(text.contains("/my/jdk"), "a JDK path is never shared")

        let loaded = try XCTUnwrap(JavaProjectRunConfigurationFolder(root: project).configurations().first)
        XCTAssertEqual(loaded.id, configuration.id)
        XCTAssertEqual(loaded.target, configuration.target, "paths are resolved against the project again")
        XCTAssertEqual(loaded.workingDirectory, configuration.workingDirectory)
        XCTAssertEqual(loaded.redirectInputPath, "/elsewhere/input.txt")
        XCTAssertNil(loaded.jdkHome)
        XCTAssertTrue(loaded.storeAsProjectFile)
    }

    func testAMovedCheckoutStillResolvesItsPaths() throws {
        let folder = JavaProjectRunConfigurationFolder(root: project)
        folder.save(mainConfiguration("Server", shared: true))
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: project, to: moved)
        let loaded = try XCTUnwrap(JavaProjectRunConfigurationFolder(root: moved).configurations().first)
        XCTAssertEqual(loaded.target, .classpathMain(className: "app.A", sourceFile: moved.appendingPathComponent("src/A.java").path))
    }

    func testRenamingMovesTheFileAndDeletingRemovesIt() {
        let folder = JavaProjectRunConfigurationFolder(root: project)
        var configuration = mainConfiguration("Old", shared: true)
        folder.save(configuration)
        let directoryURL = project.appendingPathComponent(".umbra/runConfigurations")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("Old.json").path))

        configuration.name = "New"
        folder.save(configuration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("Old.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("New.json").path))
        XCTAssertEqual(folder.configurations().map(\.id), [configuration.id])

        folder.delete(id: configuration.id)
        XCTAssertTrue(folder.configurations().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("New.json").path))
    }

    func testTwoConfigurationsWithOneNameGetTwoFiles() {
        let folder = JavaProjectRunConfigurationFolder(root: project)
        let one = mainConfiguration("Same", file: "A", shared: true)
        let two = mainConfiguration("Same", file: "B", shared: true)
        folder.save(one)
        folder.save(two)
        folder.save(one)
        XCTAssertEqual(Set(folder.configurations().map(\.id)), [one.id, two.id])
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(".umbra/runConfigurations").path).count, 2)
    }

    func testAnEditOnDiskIsSeenAndAnInvalidFileIsSkipped() throws {
        let folder = JavaProjectRunConfigurationFolder(root: project)
        folder.save(mainConfiguration("Server", shared: true))
        let directoryURL = project.appendingPathComponent(".umbra/runConfigurations")
        try Data("not json".utf8).write(to: directoryURL.appendingPathComponent("Broken.json"))
        XCTAssertEqual(folder.configurations().count, 1)

        let file = directoryURL.appendingPathComponent("Server.json")
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"programArguments\" : \"\"", with: "\"programArguments\" : \"--edited\"")
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        XCTAssertEqual(folder.configurations().first?.programArguments, "--edited")
    }

    // MARK: - Catalog

    func testSharingMovesAConfigurationBetweenTheTwoSidesAndKeepsItsId() {
        let catalog = makeCatalog()
        var configuration = mainConfiguration("Server")
        catalog.setLast(configuration, forProject: project)
        XCTAssertEqual(catalog.store.configurations(forProject: project).count, 1)

        configuration.storeAsProjectFile = true
        catalog.save(configuration, forProject: project)
        XCTAssertTrue(catalog.store.configurations(forProject: project).isEmpty, "no longer kept on this Mac")
        XCTAssertEqual(JavaProjectRunConfigurationFolder(root: project).configurations().map(\.id), [configuration.id])
        XCTAssertEqual(catalog.configurations(forProject: project).map(\.id), [configuration.id])
        XCTAssertEqual(catalog.last(forProject: project)?.id, configuration.id, "the selection survives the move")

        configuration.storeAsProjectFile = false
        catalog.save(configuration, forProject: project)
        XCTAssertTrue(JavaProjectRunConfigurationFolder(root: project).configurations().isEmpty)
        XCTAssertEqual(catalog.store.configurations(forProject: project).map(\.id), [configuration.id])
    }

    func testTheSelectionIsPerMacEvenForASharedConfiguration() {
        let catalog = makeCatalog()
        let shared = mainConfiguration("Shared", file: "S", shared: true)
        let local = mainConfiguration("Local", file: "L")
        catalog.save(shared, forProject: project)
        catalog.setLast(local, forProject: project)
        XCTAssertEqual(catalog.last(forProject: project)?.id, local.id)
        catalog.select(shared.id, forProject: project)
        XCTAssertEqual(catalog.last(forProject: project)?.id, shared.id)
        XCTAssertEqual(catalog.configurations(forProject: project).map(\.id), [local.id, shared.id], "local first, then shared")

        catalog.delete(shared.id, forProject: project)
        XCTAssertEqual(catalog.last(forProject: project)?.id, local.id)
        XCTAssertTrue(JavaProjectRunConfigurationFolder(root: project).configurations().isEmpty)
    }

    func testDuplicateKeepsASharedConfigurationShared() {
        let catalog = makeCatalog()
        let shared = mainConfiguration("Shared", shared: true)
        catalog.save(shared, forProject: project)
        let copy = catalog.duplicate(shared.id, forProject: project)
        XCTAssertEqual(copy?.name, "Shared copy")
        XCTAssertEqual(copy?.storeAsProjectFile, true)
        XCTAssertEqual(JavaProjectRunConfigurationFolder(root: project).configurations().count, 2)
        XCTAssertEqual(catalog.last(forProject: project)?.id, copy?.id)
    }

    func testMovingToAFolderAndOut() {
        let catalog = makeCatalog()
        let configuration = mainConfiguration("Server")
        catalog.save(configuration, forProject: project)
        catalog.move(configuration.id, toFolder: "  Servers ", forProject: project)
        XCTAssertEqual(catalog.configurations(forProject: project).first?.folder, "Servers")
        catalog.move(configuration.id, toFolder: " ", forProject: project)
        XCTAssertNil(catalog.configurations(forProject: project).first?.folder)
    }

    func testAProjectWithoutAFolderOnlyHasLocalConfigurations() {
        let catalog = makeCatalog()
        let shared = mainConfiguration("Shared", shared: true)
        catalog.save(shared, forProject: nil)
        XCTAssertEqual(catalog.configurations(forProject: nil).map(\.id), [shared.id])
        XCTAssertEqual(catalog.store.configurations(forProject: nil).count, 1, "with no project there is nowhere to share it")
    }
}
