import EditorIntelligence
import EditorIntelligenceLSP
import XCTest
@testable import Umbra

/// Generating the compilation database for an Xcode project: what is asked of `xcodebuild`, what is
/// written where, what SourceKit-LSP is told, and what a failure leaves behind.
@MainActor
final class IDEXcodeIndexDatabaseTests: XCTestCase {
    private var directory: URL!
    private var caches: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-xidx-\(UUID().uuidString)", isDirectory: true)
        caches = directory.appendingPathComponent("caches", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A project the app's own template writes, so `findProject` and the model see a real one.
    private func makeApp() throws -> URL {
        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.xcode.macos-app"))
        return try IDEProjectWriter.create(template, options: IDENewProjectOptions(name: "My App", parentDirectory: directory))
    }

    /// A PATH whose first entry holds an `xcodebuild` running `script`; `/bin` and `/usr/bin` stay for `cat`.
    private func installXcodebuild(script: String) throws -> [String: String] {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("xcodebuild")
        try "#!/bin/sh\n\(script)\n".write(to: tool, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return ["PATH": bin.path + ":/bin:/usr/bin"]
    }

    /// The JSON a fake `xcodebuild` prints: one module of two files.
    private func writeSettings(for root: URL) throws -> URL {
        let files = [root.path + "/My App/A.swift", root.path + "/My App/B.swift"]
        let arguments = ["-module-name", "MyApp"] + files + ["-sdk", "/SDK"]
        let entries = Dictionary(uniqueKeysWithValues: files.map { ($0, ["swiftASTCommandArguments": arguments, "swiftASTModuleName": "MyApp"]) })
        let url = directory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["My App": entries]).write(to: url)
        return url
    }

    func testItAsksXcodebuildForTheIndexSettingsOfEveryTargetAndWritesTheDatabase() async throws {
        let root = try makeApp()
        let settings = try writeSettings(for: root)
        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let environment = try installXcodebuild(script: "echo \"$@\" > '\(argumentsFile.path)'\ncat '\(settings.path)'")

        let outcome = await IDEXcodeIndexDatabase.generate(root: root, caches: caches, environment: environment)
        XCTAssertEqual(outcome, .generated(files: 2, modules: 1))

        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
        for expected in ["-project", "My App.xcodeproj", "-alltargets", "-showBuildSettingsForIndex", "-json", "-skipPackageUpdates"] {
            XCTAssertTrue(arguments.contains(expected), "\(expected) in \(arguments)")
        }
        let folder = IDEXcodeIndexDatabase.directory(for: root, caches: caches)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names.filter { $0.hasSuffix(".rsp") }.count, 1)
        XCTAssertTrue(names.contains("compile_commands.json"))
        let database = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("compile_commands.json"))) as? [[String: Any]]
        let files = Set(database?.compactMap { $0["file"] as? String } ?? [])
        XCTAssertTrue(files.contains(root.path + "/My App/A.swift") && files.contains(root.path + "/My App/B.swift"), "\(files)")
        XCTAssertEqual((database?.first?["arguments"] as? [String])?.first, "swiftc")
    }

    func testTheServerIsToldWhereTheDatabaseIsRelativeToTheProject() async throws {
        let root = try makeApp()
        XCTAssertNil(IDEXcodeIndexDatabase.initializationOptions(for: root, caches: caches), "no database yet")
        let settings = try writeSettings(for: root)
        let environment = try installXcodebuild(script: "cat '\(settings.path)'")
        _ = await IDEXcodeIndexDatabase.generate(root: root, caches: caches, environment: environment)

        let data = try XCTUnwrap(IDEXcodeIndexDatabase.initializationOptions(for: root, caches: caches))
        let options = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let search = try XCTUnwrap(((options["compilationDatabase"] as? [String: Any])?["searchPaths"]) as? [String])
        XCTAssertEqual(search.count, 1)
        XCTAssertFalse(search[0].hasPrefix("/"), "an absolute path outside the workspace is ignored by the server: \(search[0])")
        // The server follows symlinks in the folder (the temporary directory is under `/var`) before the `..`.
        let realRoot = URL(fileURLWithPath: try XCTUnwrap(IDEXcodeIndexSettings.realPath(root.path)))
        let realCache = try XCTUnwrap(IDEXcodeIndexSettings.realPath(IDEXcodeIndexDatabase.directory(for: root, caches: caches).path))
        let resolved = URL(fileURLWithPath: search[0], relativeTo: realRoot).standardizedFileURL.path
        XCTAssertEqual(IDEXcodeIndexSettings.realPath(resolved), realCache)
    }

    func testAFolderWithAPackageGetsNoDatabaseOptions() async throws {
        let root = try makeApp()
        let settings = try writeSettings(for: root)
        let environment = try installXcodebuild(script: "cat '\(settings.path)'")
        _ = await IDEXcodeIndexDatabase.generate(root: root, caches: caches, environment: environment)
        XCTAssertNotNil(IDEXcodeIndexDatabase.initializationOptions(for: root, caches: caches))

        try "import PackageDescription\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        XCTAssertNil(IDEXcodeIndexDatabase.initializationOptions(for: root, caches: caches), "SourceKit-LSP reads a package by itself")
        XCTAssertFalse(IDEXcodeIndexDatabase.isXcodeOnly(root: root))
    }

    func testAFailedRunKeepsThePreviousDatabase() async throws {
        let root = try makeApp()
        let settings = try writeSettings(for: root)
        var environment = try installXcodebuild(script: "cat '\(settings.path)'")
        let first = await IDEXcodeIndexDatabase.generate(root: root, caches: caches, environment: environment)
        XCTAssertTrue(first.isUsable)
        let folder = IDEXcodeIndexDatabase.directory(for: root, caches: caches)
        let before = try Data(contentsOf: folder.appendingPathComponent("compile_commands.json"))

        environment = try installXcodebuild(script: "echo 'error: broken project' >&2\nexit 65")
        let failed = await IDEXcodeIndexDatabase.generate(root: root, caches: caches, environment: environment)
        guard case .failed(let reason) = failed else { return XCTFail("expected a failure, got \(failed)") }
        XCTAssertTrue(reason.contains("65") && reason.contains("broken project"), reason)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("compile_commands.json")), before)
        XCTAssertNotNil(IDEXcodeIndexDatabase.initializationOptions(for: root, caches: caches), "the stale database still serves")
    }

    func testOutputThatIsNotIndexSettingsAndProjectsWithNoSwiftFail() async throws {
        let root = try makeApp()
        var environment = try installXcodebuild(script: "echo 'hello'")
        let garbage = await IDEXcodeIndexDatabase.generate(root: root, caches: caches, environment: environment)
        XCTAssertEqual(garbage, .failed("xcodebuild did not print index settings."))

        environment = try installXcodebuild(script: "echo '{\"App\": {\"/x/main.m\": {\"clangASTCommandArguments\": [\"-x\"]}}}'")
        let none = await IDEXcodeIndexDatabase.generate(root: root, caches: caches, environment: environment)
        XCTAssertEqual(none, .unavailable("The project has no Swift sources."))
    }

    func testNothingToGenerateFromOrWith() async throws {
        let empty = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let noProject = await IDEXcodeIndexDatabase.generate(root: empty, caches: caches)
        XCTAssertEqual(noProject, .unavailable("No Xcode project in this folder."))

        let root = try makeApp()
        let none = directory.appendingPathComponent("no-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: none, withIntermediateDirectories: true)
        let missing = await IDEXcodeIndexDatabase.generate(root: root, caches: caches, environment: ["PATH": none.path])
        XCTAssertEqual(missing, .unavailable("xcodebuild was not found."))
    }

    /// The whole chain on a real Xcode project: the template writes it, `xcodebuild` is asked for its index
    /// settings, the host prepares the database, hands the server its relative path and syncs the open
    /// buffer, and the server completes a member of a type declared in *another file* of the project. With
    /// no database the server sees one file at a time and offers nothing. Skips without Xcode's tools.
    func testARealXcodeProjectGivesTheServerKnowledgeOfItsOtherFiles() async throws {
        let definition = IDESourceKitServer.definition()
        let context = IDEServerDiscoveryContext(root: directory, environment: ProcessInfo.processInfo.environment)
        guard await definition.discover(context) != nil else { throw XCTSkip("No sourcekit-lsp on this machine") }
        guard IDEXcodeProjectSystem.resolveXcodebuild(environment: nil) != nil else { throw XCTSkip("No xcodebuild on this machine") }

        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.xcode.command-line-tool"))
        let options = IDENewProjectOptions(name: "Tool", parentDirectory: directory)
        let root = try IDEProjectWriter.create(template, options: options)
        defer { try? FileManager.default.removeItem(at: IDEXcodeIndexDatabase.directory(for: root)) }
        let sources = root.appendingPathComponent(options.productName, isDirectory: true)
        try "struct Gadget {\n    var sprocket = 1\n}\n".write(to: sources.appendingPathComponent("Gadget.swift"), atomically: true, encoding: .utf8)
        let main = sources.appendingPathComponent("main.swift")

        // The editor's buffer: the file on disk does not use `Gadget`; the buffer does, mid-edit.
        let text = "let g = Gadget()\nprint(g.)\n"
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let buffer = Document(
            url: main, displayName: "main.swift",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "swift"
        )
        let workspace = Workspace()
        await workspace.openDocument(buffer)

        let box = LSPConnectionBox()
        let host = IDELanguageServerHost(trustDirectory: directory.appendingPathComponent("trust", isDirectory: true))
        host.documentWorkspace = workspace
        host.trust(definition, root: root)
        await host.start(definition, connection: box, root: root)
        defer { host.stop() }

        let position = TextPosition(line: 1, column: 8, utf16Offset: 25)
        var names: [String] = []
        let deadline = Date().addingTimeInterval(90)
        while !names.contains("sprocket"), Date() < deadline {
            if let client = box.current as? LanguageServerClient,
               let items = try? await client.requestCompletions(for: buffer, at: position) {
                names = items.map { ($0.filterText ?? $0.label).components(separatedBy: "(")[0] }
            }
            if !names.contains("sprocket") { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        var serverDiagnostics = "none"
        if let client = box.current as? LanguageServerClient {
            let published = (try? await client.requestDiagnostics(for: buffer)) ?? []
            serverDiagnostics = published.map(\.message).joined(separator: " | ")
        }
        let folder = IDEXcodeIndexDatabase.directory(for: root)
        let database = (try? String(contentsOf: folder.appendingPathComponent("compile_commands.json"), encoding: .utf8)) ?? "NO DATABASE"
        let response = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).first { $0.hasSuffix(".rsp") }
            .flatMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) } ?? "NO RESPONSE FILE"
        let serverOptions = IDEXcodeIndexDatabase.initializationOptions(for: root).map { String(decoding: $0, as: UTF8.self) } ?? "NO OPTIONS"
        XCTAssertTrue(
            names.contains("sprocket"),
            "a member declared in Gadget.swift, seen from main.swift: \(names.prefix(10)); status \(host.summary ?? "none")\nserver diagnostics: \(serverDiagnostics)\nroot \(root.path)\noptions \(serverOptions)\ndatabase \(database.prefix(900))\nresponse \(response.suffix(2200))"
        )
    }

    func testTheCacheFolderIsPerProjectAndOutsideIt() throws {
        let one = directory.appendingPathComponent("one", isDirectory: true)
        let two = directory.appendingPathComponent("two", isDirectory: true)
        let a = IDEXcodeIndexDatabase.directory(for: one, caches: caches)
        XCTAssertNotEqual(a, IDEXcodeIndexDatabase.directory(for: two, caches: caches))
        XCTAssertEqual(a, IDEXcodeIndexDatabase.directory(for: one, caches: caches), "stable for a folder")
        XCTAssertFalse(a.path.hasPrefix(one.path), "nothing is written into the user's project")
    }
}
