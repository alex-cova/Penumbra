import EditorIntelligence
import EditorIntelligenceLSP
import Penumbra
import XCTest
@testable import Umbra

/// The catalog of 15 languages. Everything here is deterministic and uses no real server except the two
/// tests marked REAL SERVER, which skip (and say so) when the binary is not installed.
@MainActor
final class IDELanguageServerCatalogTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-catalog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func touch(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    // MARK: Registry

    func testAllFifteenLanguagesAreRegisteredOnceAndRouteFromTheirFiles() {
        let expected: [String: String] = [
            "php": "intelephense", "rust": "rust-analyzer", "csharp": "csharp-ls", "kotlin": "kotlin-lsp", "scala": "metals",
            "zig": "zls", "terraform": "terraform-ls", "ruby": "ruby-lsp", "r": "r-languageserver",
            "lua": "lua-language-server", "go": "gopls", "dart": "dart-analysis-server", "c": "clangd", "cpp": "clangd",
            "shell": "bash-language-server",
        ]
        XCTAssertEqual(expected.count, 15)
        for (language, server) in expected {
            XCTAssertEqual(IDELanguageServerCatalog.spec(forLanguage: language)?.id, server, language)
        }
        let ids = IDELanguageServerCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids key connection boxes and trust files")
        let files: [String: String] = [
            "a.php": "php", "a.rs": "rust", "a.cs": "csharp", "a.kt": "kotlin", "a.scala": "scala", "a.zig": "zig",
            "main.tf": "terraform", "a.rb": "ruby", "a.R": "r", "a.lua": "lua", "a.go": "go", "a.dart": "dart",
            "a.c": "c", "a.cpp": "cpp", "a.sh": "shell", "Gemfile": "ruby",
        ]
        for (file, language) in files {
            XCTAssertEqual(LanguageIdentifier.identifier(for: URL(fileURLWithPath: "/p/\(file)")), language, file)
        }
    }

    func testEveryServerHasLaunchAndInstallGuidance() {
        for spec in IDELanguageServerCatalog.all {
            XCTAssertFalse(spec.executables.isEmpty, spec.id)
            XCTAssertFalse(spec.installInstructions.isEmpty, "\(spec.id) must say how to install it")
            XCTAssertNotNil(URL(string: spec.installURL), spec.id)
            XCTAssertFalse(spec.licence.isEmpty, spec.id)
            XCTAssertTrue(!spec.projectMarkers.isEmpty || !spec.sourceExtensions.isEmpty, spec.id)
            let definition = IDECatalogServer.definition(for: spec)
            XCTAssertEqual(definition.trustFile, "\(spec.id)-trust.json")
            XCTAssertEqual(definition.configuration.languageIdentifiers, Set(spec.languageIDs))
            XCTAssertFalse(definition.configuration.enabledFeatures.contains(.semanticTokens), "see IDEPythonServer.features")
        }
    }

    func testLaunchArgumentsAndLSPLanguageIDs() {
        func args(_ id: String) -> [String] { IDELanguageServerCatalog.spec(id: id)!.arguments }
        XCTAssertEqual(args("dart-analysis-server"), ["language-server", "--protocol=lsp"])
        XCTAssertEqual(args("terraform-ls"), ["serve"])
        XCTAssertEqual(args("bash-language-server"), ["start"])
        XCTAssertEqual(args("intelephense"), ["--stdio"])
        XCTAssertTrue(args("r-languageserver").contains("languageserver::run()"))
        let bash = IDECatalogServer.definition(for: IDELanguageServerCatalog.spec(id: "bash-language-server")!)
        XCTAssertEqual(bash.configuration.lspLanguageID(nil, "shell"), "shellscript")
        let clang = IDECatalogServer.definition(for: IDELanguageServerCatalog.spec(id: "clangd")!)
        XCTAssertEqual(clang.configuration.lspLanguageID(nil, "cpp"), "cpp")
        XCTAssertEqual(clang.configuration.languageIdentifiers, ["c", "cpp"], "one clangd for both languages")
    }

    func testTheModuleIsRegisteredAndContributesOnePageAndEveryDefinition() {
        let module = IDELanguageModules.module(id: IDECatalogServersModule.id)
        XCTAssertEqual(module?.languageServers.count, 15 - 1, "clangd serves two languages: 14 servers")
        XCTAssertEqual(module?.preferencePanes.map(\.domain), [.languageServers])
    }

    // MARK: Relevance

    func testMarkersAtTheRootAndInADirectChildFolderMakeAServerRelevant() throws {
        let rust = IDELanguageServerCatalog.spec(id: "rust-analyzer")!
        XCTAssertFalse(IDEServerProjectProbe.isRelevant(rust, root: root))
        try touch("services/api/Cargo.toml")
        XCTAssertFalse(IDEServerProjectProbe.isRelevant(rust, root: root), "two levels down is not a monorepo child")
        try touch("crates/Cargo.toml")
        XCTAssertTrue(IDEServerProjectProbe.isRelevant(rust, root: root))
    }

    func testSuffixMarkersAndSourceFilesAndSkippedFolders() throws {
        let csharp = IDELanguageServerCatalog.spec(id: "csharp-ls")!
        try touch("App.sln")
        XCTAssertTrue(IDEServerProjectProbe.isRelevant(csharp, root: root))
        let lua = IDELanguageServerCatalog.spec(id: "lua-language-server")!
        try touch("node_modules/dep/x.lua")
        XCTAssertFalse(IDEServerProjectProbe.isRelevant(lua, root: root), "dependency folders are not scanned")
        try touch("scripts/x.lua")
        XCTAssertTrue(IDEServerProjectProbe.isRelevant(lua, root: root), "a folder of loose scripts has no marker")
    }

    func testKotlinNeedsKotlinSourcesNotJustAGradleBuild() throws {
        let kotlin = IDELanguageServerCatalog.spec(id: "kotlin-lsp")!
        try touch("build.gradle.kts")
        try touch("src/main/java/A.java")
        XCTAssertFalse(IDEServerProjectProbe.isRelevant(kotlin, root: root), "a Java Gradle project keeps the native engine alone")
        try touch("src/main/kotlin/A.kt")
        XCTAssertTrue(IDEServerProjectProbe.isRelevant(kotlin, root: root))
    }

    func testClangdStartsForLooseCSourcesAndNeverForAnEmptyFolder() throws {
        let clangd = IDELanguageServerCatalog.spec(id: "clangd")!
        try touch("CMakeLists.txt")
        XCTAssertFalse(IDEServerProjectProbe.isRelevant(clangd, root: root), "CMake alone is not C")
        try touch("main.c")
        XCTAssertTrue(IDEServerProjectProbe.isRelevant(clangd, root: root))
    }

    func testTheScanIsBoundedByEntryCount() throws {
        let lua = IDELanguageServerCatalog.spec(id: "lua-language-server")!
        for index in 0..<(IDEServerProjectProbe.maxSourceEntries + 50) { try touch("f\(index).txt") }
        try touch("deep/zz.lua")
        XCTAssertFalse(IDEServerProjectProbe.hasSource(lua, root: root), "a huge folder is cut off, not walked")
    }

    // MARK: Discovery

    func testDiscoveryOrderOverrideThenProjectThenPathThenToolchainDirectories() throws {
        let spec = IDELanguageServerCatalog.spec(id: "bash-language-server")!
        let home = URL(fileURLWithPath: "/Users/test")
        let present: Set<String> = [
            "/p/node_modules/.bin/bash-language-server", "/usr/bin/bash-language-server", "/opt/homebrew/bin/bash-language-server",
            "/custom/bls",
        ]
        let isExecutable: (String) -> Bool = { present.contains($0) }
        let project = URL(fileURLWithPath: "/p")
        func locate(_ override: String?, path: [String] = ["/usr/bin"]) -> String? {
            IDEServerLocator.locate(spec: spec, root: project, override: override, searchPath: path, home: home, isExecutable: isExecutable)?.path
        }
        XCTAssertEqual(locate("/custom/bls"), "/custom/bls")
        XCTAssertNil(locate("/missing/bls"), "a bad override is reported missing, never swapped for another binary")
        XCTAssertEqual(locate(nil), "/p/node_modules/.bin/bash-language-server")
        let noLocal = IDEServerLocator.locate(
            spec: spec, root: URL(fileURLWithPath: "/q"), override: nil, searchPath: ["/usr/bin"], home: home, isExecutable: isExecutable
        )
        XCTAssertEqual(noLocal?.path, "/usr/bin/bash-language-server")
        let homebrewOnly = IDEServerLocator.locate(
            spec: spec, root: URL(fileURLWithPath: "/q"), override: nil, searchPath: [], home: home, isExecutable: isExecutable
        )
        XCTAssertEqual(homebrewOnly?.path, "/opt/homebrew/bin/bash-language-server", "a GUI app's PATH lacks Homebrew")
    }

    func testTildeDirectoriesExpandAgainstHome() {
        let spec = IDELanguageServerCatalog.spec(id: "rust-analyzer")!
        let found = IDEServerLocator.locate(
            spec: spec, root: root, override: nil, searchPath: [], home: URL(fileURLWithPath: "/Users/test"),
            isExecutable: { $0 == "/Users/test/.cargo/bin/rust-analyzer" }
        )
        XCTAssertEqual(found?.path, "/Users/test/.cargo/bin/rust-analyzer")
    }

    func testTheChildEnvironmentGetsAToolchainPathWithoutDuplicates() {
        let env = IDEServerLocator.environment(base: ["PATH": "/usr/bin:/bin", "HOME": "/h"], searchPath: ["/usr/bin", "/x/bin"], extraDirectories: ["/y"])
        let entries = IDEServerLocator.pathEntries(env["PATH"])
        XCTAssertEqual(entries.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertTrue(entries.contains("/x/bin") && entries.contains("/opt/homebrew/bin") && entries.contains("/y"))
        XCTAssertEqual(env["HOME"], "/h")
    }

    func testVersionTextIsTheFirstNonEmptyLineAndBounded() {
        XCTAssertEqual(IDEServerVersion.firstLine("\n  clangd version 18.1\nmore"), "clangd version 18.1")
        XCTAssertNil(IDEServerVersion.firstLine(" \n"))
        XCTAssertEqual(IDEServerVersion.firstLine(String(repeating: "x", count: 500))?.count, 120)
    }

    func testDisablingAServerKeepsItOutOfTheFolder() throws {
        let spec = IDELanguageServerCatalog.spec(id: "zls")!
        try touch("build.zig")
        let key = spec.enabledDefaultsKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertTrue(IDECatalogServer.definition(for: spec).isRelevantToProject(root))
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(IDECatalogServer.definition(for: spec).isRelevantToProject(root))
    }

    // MARK: Lifecycle (fake child processes)

    private func scriptServer(id: String, script: String) -> IDELanguageServerDefinition {
        IDELanguageServerDefinition(
            id: id,
            configuration: LSPLanguageConfiguration(name: id, languageIdentifiers: ["lua"], diagnosticSource: DiagnosticSourceID(rawValue: id)),
            discover: { _ in IDEServerExecutable(url: URL(fileURLWithPath: "/bin/sh")) },
            arguments: { _ in ["-c", script] },
            trustFile: "\(id)-trust.json"
        )
    }

    func testAServerThatKeepsDyingStopsAtTheRestartLimitWithItsError() async throws {
        let marker = root.appendingPathComponent("launches")
        let definition = scriptServer(id: "dying", script: "echo x >> \(marker.path); echo boom-from-server >&2; exit 3")
        let host = IDELanguageServerHost(trustDirectory: root)
        host.restartDelay = { _ in .milliseconds(5) }
        host.maxRestartAttempts = 3
        host.trust(definition, root: root)
        await host.start(definition, connection: LSPConnectionBox(), root: root)
        let deadline = Date().addingTimeInterval(8)
        while host.statuses.first?.phase != .failed, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        host.stop()
        XCTAssertEqual(host.statuses.first?.phase, nil) // stop() clears; the assertions below used the live state
        let launches = (try? String(contentsOf: marker, encoding: .utf8))?.split(separator: "\n").count ?? 0
        XCTAssertEqual(launches, 4, "the first launch plus three restarts, then no endless loop")
    }

    func testFailedStateAndStderrAreReported() async throws {
        let definition = scriptServer(id: "dying2", script: "echo boom-from-server >&2; exit 3")
        let host = IDELanguageServerHost(trustDirectory: root)
        host.restartDelay = { _ in .milliseconds(5) }
        host.maxRestartAttempts = 1
        host.trust(definition, root: root)
        await host.start(definition, connection: LSPConnectionBox(), root: root)
        let deadline = Date().addingTimeInterval(8)
        while host.statuses.first?.phase != .failed, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(host.statuses.first?.phase, .failed)
        XCTAssertTrue(host.serverErrors["dying2"]?.contains("boom-from-server") == true)
        XCTAssertEqual(host.summary, "dying2: stopped after repeated crashes")
        host.stop()
    }

    func testRestartReplacesTheProcessAndTheOldExitDoesNotClearTheNewSession() async throws {
        let marker = root.appendingPathComponent("sleeps")
        let definition = scriptServer(id: "sleeper", script: "echo x >> \(marker.path); sleep 30")
        let box = LSPConnectionBox()
        let host = IDELanguageServerHost(trustDirectory: root)
        host.restartDelay = { _ in .seconds(30) }
        host.trust(definition, root: root)
        host.projectDidChange(root: nil, connections: [:]) // sets no root
        await host.start(definition, connection: box, root: root)
        func launches() -> Int { (try? String(contentsOf: marker, encoding: .utf8))?.split(separator: "\n").count ?? 0 }
        var deadline = Date().addingTimeInterval(3)
        while launches() < 1, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(launches(), 1)
        // `restart` needs the folder `projectDidChange` recorded; the catalog never reaches it without one.
        host.restart(definition, connection: box)
        XCTAssertEqual(launches(), 1, "no folder, no restart")
        host.stop()
    }

    // MARK: REAL SERVER

    private func realServerOrSkip(_ id: String) async throws -> (IDELanguageServerSpec, IDEServerExecutable) {
        let spec = IDELanguageServerCatalog.spec(id: id)!
        let context = IDEServerDiscoveryContext(root: root, environment: ProcessInfo.processInfo.environment)
        guard let executable = await IDECatalogServer.discover(spec, context: context) else {
            throw XCTSkip("\(spec.executables[0]) is not installed on this machine")
        }
        // A rustup proxy exists for components that are not installed; it exits with an error on every run.
        if spec.versionArguments != nil,
           await IDEServerVersion.read(spec: spec, executable: executable.url, environment: executable.environment) == nil {
            throw XCTSkip("\(executable.url.path) is present but does not run (`\(spec.versionArguments!.joined(separator: " "))` failed)")
        }
        return (spec, executable)
    }

    /// REAL SERVER: clangd. Launches through the host with the buffer (not the file on disk) open, and reads its outline.
    func testRealClangdSeesTheOpenBufferAndAdvertisesCapabilities() async throws {
        let (spec, _) = try await realServerOrSkip("clangd")
        let file = root.appendingPathComponent("main.c")
        try "int disk_only(void) { return 0; }\n".write(to: file, atomically: true, encoding: .utf8)
        let text = "int buffer_only(int a) { return a; }\nint main(void) { return buffer_only(1); }\n"
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let buffer = Document(
            url: file, displayName: "main.c", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "c"
        )
        let workspace = Workspace()
        await workspace.openDocument(buffer)
        let definition = IDECatalogServer.definition(for: spec)
        let box = LSPConnectionBox()
        let host = IDELanguageServerHost(trustDirectory: root.appendingPathComponent("trust", isDirectory: true))
        host.documentWorkspace = workspace
        host.trust(definition, root: root)
        let clock = ContinuousClock()
        let launchedAt = clock.now
        await host.start(definition, connection: box, root: root)
        defer { host.stop() }

        var names: [String] = []
        let deadline = Date().addingTimeInterval(30)
        while !names.contains("buffer_only"), Date() < deadline {
            if let client = box.current as? LanguageServerClient,
               let symbols = try? await client.requestDocumentSymbols(for: buffer) {
                func flat(_ items: [LSPOutlineSymbol]) -> [String] { items.flatMap { [$0.name] + flat($0.children) } }
                names = flat(symbols)
            }
            if !names.contains("buffer_only") { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        var lastError = "none"
        if let client = box.current as? LanguageServerClient {
            do { _ = try await client.requestDocumentSymbols(for: buffer) } catch { lastError = "\(error)" }
        }
        print("LSPTIMING clangd launch→first outline of the open buffer: \(launchedAt.duration(to: clock.now))")
        XCTAssertTrue(names.contains("buffer_only"), "last error \(lastError); clangd never saw the buffer; outline: \(names); phase \(String(describing: host.statuses.first?.phase)); stderr \(host.serverErrors); client \(String(describing: box.current))")
        XCTAssertFalse(names.contains("disk_only"))
        XCTAssertEqual(host.statuses.first?.phase, .ready)
        let supported = try XCTUnwrap(box.supportedFeatures)
        XCTAssertTrue(supported.contains(.completion) && supported.contains(.definition), "clangd advertised \(supported.map(\.rawValue).sorted())")
    }

    /// REAL SERVER: rust-analyzer launches and completes `initialize` for a Cargo project (launch verified only).
    func testRealRustAnalyzerInitializes() async throws {
        let (spec, _) = try await realServerOrSkip("rust-analyzer")
        try touch("src/main.rs")
        try "[package]\nname = \"fx\"\nversion = \"0.1.0\"\nedition = \"2021\"\n".write(
            to: root.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8
        )
        try "fn main() {}\n".write(to: root.appendingPathComponent("src/main.rs"), atomically: true, encoding: .utf8)
        let definition = IDECatalogServer.definition(for: spec)
        XCTAssertTrue(definition.isRelevantToProject(root))
        let box = LSPConnectionBox()
        let host = IDELanguageServerHost(trustDirectory: root.appendingPathComponent("trust", isDirectory: true))
        host.trust(definition, root: root)
        await host.start(definition, connection: box, root: root)
        defer { host.stop() }
        let deadline = Date().addingTimeInterval(60)
        while host.statuses.first?.phase != .ready, Date() < deadline { try await Task.sleep(nanoseconds: 250_000_000) }
        XCTAssertEqual(host.statuses.first?.phase, .ready)
        XCTAssertTrue(box.supportedFeatures?.contains(.completion) == true)
    }
}
