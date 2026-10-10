import AppKit
import Foundation
import JavaIntelligence
import Penumbra
import XCTest
@testable import Umbra

/// npm beside Gradle: the manifest, trust, a fake `npm` on PATH, the TypeScript diagram and index.
@MainActor
final class IDENpmProjectSystemTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private func waitUntil(seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-npm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "umbra.npm.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func makeNpm(in directory: URL, defaults: UserDefaults) -> (IDENpmProjectSystem, GradleTrustStore) {
        let store = GradleTrustStore(storeURL: directory.appendingPathComponent("npm-trust.json"))
        let npm = IDENpmProjectSystem(status: IDEProjectStatus(), trustStore: store, scriptDefaults: defaults)
        return (npm, store)
    }

    /// An executable named `npm` whose PATH entry comes first. `/bin` and `/usr/bin` stay so `sleep` resolves.
    private func installNpm(script: String, in directory: URL) throws -> [String: String] {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let npm = bin.appendingPathComponent("npm")
        try "#!/bin/sh\n\(script)\n".write(to: npm, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)
        return ["PATH": bin.path + ":/bin:/usr/bin"]
    }

    private func consoleText(_ npm: IDENpmProjectSystem) -> String {
        npm.console.lines.map(\.text).joined(separator: "\n")
    }

    private func writePackage(_ json: String, in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try json.write(to: root.appendingPathComponent("package.json"), atomically: false, encoding: .utf8)
    }

    // MARK: - Manifest and diagram

    func testManifestKeepsSourceOrderAndTheDiagramLabelsEachRange() throws {
        let json = """
        {
          "name": "demo",
          "nested": { "scripts": { "hidden": "no" } },
          "scripts": {
            "zebra": "z",
            "alpha": "a",
            "skip": 1,
            "middle": "node -e \\"console.log(1)\\""
          },
          "dependencies": { "left": "1.0.0", "same": "1.0.0" },
          "devDependencies": { "same": "2.0.0" },
          "peerDependencies": { "peer": "^1" },
          "optionalDependencies": { "opt": "3.0.0" }
        }
        """
        let manifest = try XCTUnwrap(IDENpmManifest.parse(data: Data(json.utf8), folderName: "folder"))
        XCTAssertEqual(manifest.packageName, "demo")
        XCTAssertEqual(manifest.scripts.map(\.name), ["zebra", "alpha", "middle"])
        XCTAssertEqual(manifest.scripts.first { $0.name == "middle" }?.command, "node -e \"console.log(1)\"")
        XCTAssertEqual(manifest.dependencyCount, 5)
        XCTAssertEqual(manifest.dependencies.map(\.section), [
            "dependencies", "dependencies", "devDependencies", "peerDependencies", "optionalDependencies"
        ])

        let document = IDENpmDiagram.document(manifest: manifest, title: "Dependencies")
        let package = try XCTUnwrap(document.nodes.first { $0.kind == .project })
        XCTAssertEqual(package.key, "npm:demo")
        XCTAssertFalse(package.key.hasPrefix("project:"))
        XCTAssertEqual(package.subtitle, "package")
        let sameEdges = document.edges.filter { document.node(id: $0.destinationID)?.title == "same" }
        XCTAssertEqual(Set(sameEdges.map(\.label)), ["1.0.0", "2.0.0"])
        XCTAssertEqual(Set(sameEdges.map(\.id)).count, 2)
        XCTAssertEqual(document.nodes.filter { $0.key == "npm-dep:same" }.count, 1)

        let nameless = try XCTUnwrap(IDENpmManifest.parse(data: Data(#"{"name":""}"#.utf8), folderName: "widget"))
        XCTAssertEqual(nameless.packageName, "widget")
        XCTAssertNil(IDENpmManifest.parse(data: Data("not json".utf8), folderName: "widget"))
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(Data("{}".utf8))
        let empty = try XCTUnwrap(IDENpmManifest.parse(data: bom, folderName: "widget"))
        XCTAssertEqual(empty.packageName, "widget")
        XCTAssertEqual(empty.dependencyCount, 0)
        let bare = IDENpmDiagram.document(manifest: empty, title: "Dependencies")
        XCTAssertEqual(bare.nodes.map(\.key), ["npm:widget"])
        XCTAssertTrue(bare.edges.isEmpty)
    }

    func testOpeningParsesWithoutAskingAndABadManifestStaysActive() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (npm, _) = makeNpm(in: directory, defaults: defaults)
        defer { npm.stop() }

        var asked = 0
        npm.trustPrompt = { _ in
            asked += 1
            return false
        }
        let root = directory.appendingPathComponent("app", isDirectory: true)
        try writePackage(#"{"name":"demo","scripts":{"start":"node index.js","test":"vitest"}}"#, in: root)
        npm.projectDidChange(root: root)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(npm.syncState, .synced(modules: 1, dependencies: 0))
        XCTAssertEqual(npm.tasks, [
            IDEProjectTask(path: "start", name: "start", module: ":", group: "scripts", summary: "node index.js"),
            IDEProjectTask(path: "test", name: "test", module: ":", group: "scripts", summary: "vitest")
        ])
        XCTAssertTrue(npm.isActive)

        try "not json".write(to: root.appendingPathComponent("package.json"), atomically: false, encoding: .utf8)
        npm.projectDidChange(root: root)
        XCTAssertEqual(npm.syncState, .failed(summary: "Couldn't read package.json"))
        XCTAssertTrue(npm.isActive)
        XCTAssertTrue(npm.tasks.isEmpty)

        let plain = directory.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        npm.projectDidChange(root: plain)
        XCTAssertEqual(npm.syncState, .notDetected)
        XCTAssertFalse(npm.isActive)
        XCTAssertEqual(asked, 0)
    }

    func testADeclinedRunIsNotStoredAndADeclinedReloadIs() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (npm, trust) = makeNpm(in: directory, defaults: defaults)
        defer { npm.stop() }
        let root = directory.appendingPathComponent("app", isDirectory: true)
        try writePackage(#"{"scripts":{"start":"node index.js"}}"#, in: root)
        let sentinel = directory.appendingPathComponent("ran")
        npm.launchEnvironment = try installNpm(script: "touch \"\(sentinel.path)\"", in: directory)
        npm.trustPrompt = { _ in false }
        npm.projectDidChange(root: root)

        npm.runTasks(["start"])
        let declined = await waitUntil { self.consoleText(npm).contains("Not run") && !npm.isBusy }
        XCTAssertTrue(declined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(npm.tasks.map(\.name), ["start"])
        XCTAssertNil(trust.decision(for: root))
        XCTAssertEqual(npm.syncState, .synced(modules: 1, dependencies: 0))

        npm.reload()
        let stored = await waitUntil { trust.decision(for: root) == false }
        XCTAssertTrue(stored)
        XCTAssertEqual(npm.syncState, .untrusted)
        XCTAssertEqual(npm.tasks.map(\.name), ["start"])

        trust.setTrusted(false, for: root)
        npm.projectDidChange(root: root)
        XCTAssertEqual(npm.syncState, .untrusted)
        XCTAssertEqual(npm.tasks.map(\.name), ["start"])

        npm.trustPrompt = { _ in true }
        npm.launchEnvironment = ["PATH": ""]
        npm.runTasks(["start"])
        let agreed = await waitUntil {
            trust.decision(for: root) == true && npm.syncState == .synced(modules: 1, dependencies: 0) && !npm.isBusy
        }
        XCTAssertTrue(agreed)
        XCTAssertTrue(self.consoleText(npm).contains("No npm found on PATH"))
    }

    func testATrustedRunPrintsTheScriptAndTheExit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (npm, trust) = makeNpm(in: directory, defaults: defaults)
        defer { npm.stop() }
        let root = directory.appendingPathComponent("app", isDirectory: true)
        try writePackage(#"{"scripts":{"start":"node index.js"}}"#, in: root)
        trust.setTrusted(true, for: root)
        npm.launchEnvironment = try installNpm(
            script: "if [ \"$1\" != run ]; then echo \"bad args\" >&2; exit 2; fi\necho \"ran $2\"",
            in: directory
        )
        npm.projectDidChange(root: root)
        npm.runTasks(["start"])
        let finished = await waitUntil {
            self.consoleText(npm).contains("ran start") && self.consoleText(npm).contains("npm exited 0") && !npm.isBusy
        }
        XCTAssertTrue(finished, self.consoleText(npm))
    }

    func testCancellingARunStopsTheScript() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (npm, trust) = makeNpm(in: directory, defaults: defaults)
        defer { npm.stop() }
        let root = directory.appendingPathComponent("app", isDirectory: true)
        try writePackage(#"{"scripts":{"start":"node index.js"}}"#, in: root)
        trust.setTrusted(true, for: root)
        npm.launchEnvironment = try installNpm(
            script: "echo started\nsleep 30\necho finished",
            in: directory
        )
        npm.projectDidChange(root: root)
        npm.runTasks(["start"])
        let started = await waitUntil { self.consoleText(npm).contains("started") && npm.isBusy }
        XCTAssertTrue(started, self.consoleText(npm))
        npm.cancelTasks()
        let stopped = await waitUntil(seconds: 5) { !npm.isBusy }
        XCTAssertTrue(stopped, self.consoleText(npm))
        let text = consoleText(npm)
        XCTAssertTrue(text.contains("started"))
        XCTAssertTrue(text.contains("Cancelled"))
        XCTAssertFalse(text.contains("finished"))
    }

    func testPreferredScriptRemembersAChosenNameAndNotTheBuildButton() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (npm, trust) = makeNpm(in: directory, defaults: defaults)
        defer { npm.stop() }
        let root = directory.appendingPathComponent("app", isDirectory: true)
        try writePackage(#"{"scripts":{"lint":"eslint","test":"vitest","build":"tsc","start":"node index.js"}}"#, in: root)
        trust.setTrusted(true, for: root)
        defaults.set("test", forKey: IDENpmProjectSystem.lastScriptKey(for: root))
        npm.launchEnvironment = ["PATH": ""]
        npm.projectDidChange(root: root)
        XCTAssertEqual(npm.preferredScript, "start")

        try writePackage(#"{"scripts":{"lint":"eslint","test":"vitest","build":"tsc"}}"#, in: root)
        npm.projectDidChange(root: root)
        XCTAssertEqual(npm.preferredScript, "test")

        defaults.removeObject(forKey: IDENpmProjectSystem.lastScriptKey(for: root))
        npm.projectDidChange(root: root)
        XCTAssertEqual(npm.preferredScript, "lint")

        npm.runScript("test")
        XCTAssertEqual(defaults.string(forKey: IDENpmProjectSystem.lastScriptKey(for: root)), "test")
        let ran = await waitUntil { !npm.isBusy }
        XCTAssertTrue(ran)
        npm.runTasks(["build"])
        XCTAssertEqual(defaults.string(forKey: IDENpmProjectSystem.lastScriptKey(for: root)), "test")
        let built = await waitUntil { !npm.isBusy && self.consoleText(npm).contains("No npm found on PATH") }
        XCTAssertTrue(built, consoleText(npm))
        XCTAssertEqual(defaults.string(forKey: IDENpmProjectSystem.lastScriptKey(for: root)), "test")
    }

    // MARK: - Run provider, commands, diagrams, index

    func testRunProviderCoversTypeScriptAndJavaScript() throws {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePackage(#"{"scripts":{"start":"node index.js"}}"#, in: directory)
        workspace.npm.projectDidChange(root: directory)

        let typescript = try XCTUnwrap(workspace.runProviders.provider(forLanguage: "typescript") as? IDENpmRunProvider)
        let javascript = try XCTUnwrap(workspace.runProviders.provider(forLanguage: "javascript") as? IDENpmRunProvider)
        XCTAssertTrue(typescript === javascript)
        let document = IDERunDocument(url: directory.appendingPathComponent("main.ts"), languageIdentifier: "typescript", text: "")
        XCTAssertTrue(typescript.canRun(document))
        XCTAssertFalse(typescript.canDebug(fileURL: document.url))
        XCTAssertEqual(typescript.runHelp(fileURL: document.url), "Run npm start")
        XCTAssertEqual(typescript.debugHelp(fileURL: document.url, canRun: true), "Debugging is not available for this language")
        let markdown = IDERunDocument(url: nil, languageIdentifier: "markdown", text: "")
        XCTAssertFalse(typescript.canRun(markdown))
    }

    func testPaletteCommandsExplainWhenTheyCannotOpen() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        let ids = workspace.languageModuleCommands().map(\.id).filter {
            $0 == "typescript.showClassDiagram" || $0 == "npm.showDependencies"
        }
        XCTAssertEqual(ids, ["typescript.showClassDiagram", "npm.showDependencies"])
        workspace.languageModuleCommands().first { $0.id == "npm.showDependencies" }?.action()
        workspace.languageModuleCommands().first { $0.id == "typescript.showClassDiagram" }?.action()
        XCTAssertTrue(workspace.notifications.items.contains { $0.title == "This folder has no package.json." })
        XCTAssertTrue(workspace.notifications.items.contains { $0.title == "This file is not TypeScript." })
    }

    func testOneFileClassDiagramAndTheModuleLoader() async throws {
        let source = """
        export class Animal {}
        export class Dog extends Animal {}
        export class Cat extends Missing {}
        export interface Named { title: string }
        export enum Color { Red, Blue }
        export type Id = string
        export namespace Outer {
          export class Inner {
            #hidden: number
            run(): void {}
          }
        }
        """
        let parsed = try XCTUnwrap(TypeScriptAnalysis.parse(source))
        let file = URL(fileURLWithPath: "/tmp/Sample.ts")
        var hidden = IDEDiagramSettings()
        hidden.showPrivateMembers = false
        hidden.showExternalTypes = false
        let quiet = IDETypeScriptDiagram.document(model: parsed.model, fileURL: file, title: "Classes", settings: hidden)
        let titles = Set(quiet.nodes.map(\.title))
        XCTAssertTrue(titles.isSuperset(of: ["Animal", "Dog", "Cat", "Named", "Color", "Id", "Outer", "Inner"]))
        XCTAssertFalse(titles.contains("Missing"))
        XCTAssertEqual(quiet.nodes.first { $0.title == "Id" }?.kind, .classType)
        XCTAssertEqual(quiet.nodes.first { $0.title == "Id" }?.subtitle, "«type»")
        XCTAssertEqual(quiet.nodes.first { $0.title == "Outer" }?.subtitle, "«namespace»")
        XCTAssertEqual(quiet.nodes.first { $0.title == "Named" }?.kind, .interfaceType)
        XCTAssertEqual(quiet.nodes.first { $0.title == "Color" }?.kind, .enumType)
        XCTAssertEqual(quiet.nodes.first { $0.title == "Dog" }?.kind, .classType)
        let inner = try XCTUnwrap(quiet.nodes.first { $0.title == "Inner" })
        XCTAssertFalse(inner.attributes.contains { $0.contains("hidden") })
        XCTAssertFalse(inner.attributes.contains("Inner"))
        XCTAssertTrue(inner.methods.contains { $0.contains("run") })
        let dog = try XCTUnwrap(quiet.nodes.first { $0.title == "Dog" })
        let animal = try XCTUnwrap(quiet.nodes.first { $0.title == "Animal" })
        XCTAssertTrue(quiet.edges.contains {
            $0.kind == .inheritance && $0.sourceID == dog.id && $0.destinationID == animal.id
        })
        XCTAssertTrue(quiet.nodes.allSatisfy { $0.fileURL == file || $0.kind == .externalType })
        XCTAssertEqual(IDETypeScriptDiagram.simpleName("pkg.Foo<T>"), "Foo")

        var shown = hidden
        shown.showPrivateMembers = true
        shown.showExternalTypes = true
        let open = IDETypeScriptDiagram.document(model: parsed.model, fileURL: file, title: "Classes", settings: shown)
        let shownInner = try XCTUnwrap(open.nodes.first { $0.title == "Inner" })
        XCTAssertTrue(shownInner.attributes.contains { $0.contains("hidden") })
        XCTAssertTrue(open.nodes.contains { $0.key == "typescript-external:Missing" && $0.kind == .externalType })

        let emptyParsed = try XCTUnwrap(TypeScriptAnalysis.parse(""))
        let emptyDocument = IDETypeScriptDiagram.document(
            model: emptyParsed.model, fileURL: file, title: "Empty", settings: hidden
        )
        XCTAssertTrue(emptyDocument.nodes.isEmpty)

        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        let module = IDETypeScriptModule()
        let missing = await module.loadDiagram(
            IDEDiagramRequest(
                id: "typescript:classes:/no/such/File.ts", title: "Classes: File.ts",
                symbolName: "square.stack.3d.up", presentation: .classes
            ),
            settings: IDEDiagramSettings(), workspace: workspace
        )
        XCTAssertEqual(missing?.failure, "This TypeScript file could not be read.")
        let other = await module.loadDiagram(
            IDENpmProjectSystem.dependenciesDiagramRequest(), settings: IDEDiagramSettings(), workspace: workspace
        )
        XCTAssertNil(other)

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blank = directory.appendingPathComponent("blank.ts")
        try "const value = 1\n".write(to: blank, atomically: false, encoding: .utf8)
        let loaded = await module.loadDiagram(
            IDEDiagramRequest(
                id: "typescript:classes:" + blank.standardizedFileURL.path, title: "Classes: blank.ts",
                symbolName: "square.stack.3d.up", presentation: .classes
            ),
            settings: IDEDiagramSettings(), workspace: workspace
        )
        XCTAssertEqual(loaded?.emptyMessage, "This file declares no types.")
        XCTAssertEqual(loaded?.document.nodes.count, 0)
    }

    func testTheIndexListsTypesAndMembers() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = """
        export function helper(): void {}
        const value = 1
        export class Greeter {
          greet(): void {}
        }
        export namespace Outer {
          export class Inner {
            run(): void {}
          }
        }
        """
        try source.write(to: directory.appendingPathComponent("sample.ts"), atomically: false, encoding: .utf8)
        let index = TypeScriptIndex()
        await index.setRoot(directory)
        let empty = await index.symbols(matching: "", limit: 20)
        XCTAssertTrue(empty.isEmpty)
        let greeter = await index.symbols(matching: "Greeter", limit: 20)
        XCTAssertTrue(greeter.contains { $0.name == "Greeter" && $0.container == "" })
        let greet = await index.symbols(matching: "greet", limit: 20)
        XCTAssertTrue(greet.contains { $0.name == "greet" && $0.container == "Greeter" })
        let inner = await index.symbols(matching: "Inner", limit: 20)
        XCTAssertTrue(inner.contains { $0.name == "Inner" && $0.container == "Outer" })
        let run = await index.symbols(matching: "run", limit: 20)
        XCTAssertTrue(run.contains { $0.name == "run" && $0.container == "Inner" })
        let helper = await index.symbols(matching: "helper", limit: 20)
        XCTAssertFalse(helper.contains { $0.name == "helper" })
        let value = await index.symbols(matching: "value", limit: 20)
        XCTAssertFalse(value.contains { $0.name == "value" })
    }

    func testGradleStaysActiveBesideNpm() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gradleTrust = GradleTrustStore(storeURL: directory.appendingPathComponent("gradle-trust.json"))
        let npmTrust = GradleTrustStore(storeURL: directory.appendingPathComponent("npm-trust.json"))
        let jdk = IDEJDKSelection(store: JDKSelectionStore(storeURL: directory.appendingPathComponent("jdk.json")))
        let status = IDEProjectStatus()
        let cache = directory.appendingPathComponent("model-cache", isDirectory: true)
        let gradle = IDEGradleProjectSystem(jdk: jdk, status: status, trustStore: gradleTrust, modelCacheRoot: cache)
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let npm = IDENpmProjectSystem(status: status, trustStore: npmTrust, scriptDefaults: defaults)
        let systems = IDEProjectSystems([gradle, npm])
        defer { systems.stop() }

        let root = directory.appendingPathComponent("both", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("gradlew").path, contents: Data())
        try writePackage(#"{"scripts":{"start":"node index.js"}}"#, in: root)
        systems.projectDidChange(root: root)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(gradle.syncState, .awaitingTrust)
        XCTAssertTrue(gradle.console.lines.isEmpty)
        XCTAssertFalse(gradle.isBusy)
        XCTAssertEqual(systems.active?.id, "gradle")
        XCTAssertEqual(systems.activeSystems.map(\.id), ["gradle", "npm"])
        XCTAssertEqual(npm.tasks.map(\.name), ["start"])
    }

    func testEditingPackageJsonRaisesTheReloadBanner() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (npm, _) = makeNpm(in: directory, defaults: defaults)
        defer { npm.stop() }
        let root = directory.appendingPathComponent("app", isDirectory: true)
        try writePackage(#"{"scripts":{"start":"node index.js"}}"#, in: root)
        npm.projectDidChange(root: root)
        XCTAssertFalse(npm.hasConfigurationChanges)
        let file = root.appendingPathComponent("package.json")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let changed = await waitUntil(seconds: 2) { npm.hasConfigurationChanges }
        XCTAssertTrue(changed)
    }

    func testDiagramSessionsLoadNpmAndTypeScript() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePackage(#"{"name":"demo","dependencies":{"left":"1.0.0"}}"#, in: directory)
        let source = directory.appendingPathComponent("Greeter.ts")
        try "export class Greeter { greet(): void {} }\n".write(to: source, atomically: false, encoding: .utf8)
        workspace.npm.projectDidChange(root: directory)

        workspace.openDiagram(IDENpmProjectSystem.dependenciesDiagramRequest())
        let npmDocument = try XCTUnwrap(workspace.workbench.allDocuments().first { $0.contentKind == .diagram })
        let npmSession = try XCTUnwrap(workspace.diagramSessions[npmDocument.id])
        let npmLoaded = await waitUntil { npmSession.loadedAt != nil }
        XCTAssertTrue(npmLoaded)
        XCTAssertTrue(npmSession.document.nodes.contains { $0.key == "npm:demo" && $0.subtitle == "package" })

        let standardized = source.standardizedFileURL
        workspace.openDiagram(IDEDiagramRequest(
            id: "typescript:classes:" + standardized.path,
            title: "Classes: Greeter.ts",
            symbolName: "square.stack.3d.up",
            presentation: .classes
        ))
        let typescriptDocument = try XCTUnwrap(
            workspace.workbench.allDocuments().first { $0.displayName == "Classes: Greeter.ts" }
        )
        let typescriptSession = try XCTUnwrap(workspace.diagramSessions[typescriptDocument.id])
        let typescriptLoaded = await waitUntil { typescriptSession.loadedAt != nil }
        XCTAssertTrue(typescriptLoaded)
        XCTAssertTrue(typescriptSession.document.nodes.contains { $0.title == "Greeter" && $0.kind == .classType })
    }

    func testScriptListMovesTheSelectionAndStopsAtTheEnds() {
        let names = ["lint", "test", "build"]
        XCTAssertEqual(IDENpmScriptList.neighbor(of: nil, in: names, delta: 1), "lint")
        XCTAssertEqual(IDENpmScriptList.neighbor(of: nil, in: names, delta: -1), "build")
        XCTAssertEqual(IDENpmScriptList.neighbor(of: "test", in: names, delta: 1), "build")
        XCTAssertEqual(IDENpmScriptList.neighbor(of: "build", in: names, delta: 1), "build")
        XCTAssertEqual(IDENpmScriptList.neighbor(of: "lint", in: names, delta: -1), "lint")
        XCTAssertNil(IDENpmScriptList.neighbor(of: nil, in: [], delta: 1))
    }

    func testCommandCCopiesTheSelectedScriptOnlyWhileTheListIsFocused() {
        let view = IDENpmScriptKeyView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        var copied = 0
        view.copySelection = {
            copied += 1
            return true
        }
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = view
        let copy = keyEvent(keyCode: 8, characters: "c", flags: .command)

        view.isActive = false
        XCTAssertFalse(view.performKeyEquivalent(with: copy))
        XCTAssertEqual(copied, 0)

        view.isActive = true
        XCTAssertTrue(view.performKeyEquivalent(with: copy))
        XCTAssertEqual(copied, 1)

        let other = keyEvent(keyCode: 0, characters: "a", flags: .command)
        XCTAssertFalse(view.performKeyEquivalent(with: other))
        XCTAssertEqual(copied, 1)
    }
}
