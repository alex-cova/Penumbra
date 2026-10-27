import EditorIntelligence
import EditorIntelligenceLSP
import XCTest
@testable import Umbra

@MainActor
final class IDELanguageServerHostTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-lsp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testTheSummaryShowsWhatAReadyServerIsDoing() {
        typealias Status = IDELanguageServerHost.ServerStatus
        let ready = [Status(id: "sourcekit-lsp", name: "SourceKit-LSP", phase: .ready)]
        let indexing = LSPWorkProgress(token: "i", title: "Indexing", message: "3 / 10", percentage: 30)

        XCTAssertEqual(IDELanguageServerHost.summary(statuses: ready, work: [:]), "SourceKit-LSP")
        XCTAssertEqual(
            IDELanguageServerHost.summary(statuses: ready, work: ["sourcekit-lsp": [indexing]]),
            "SourceKit-LSP: Indexing: 3 / 10 (30%)"
        )
        let preparing = LSPWorkProgress(token: "p", title: "Preparing")
        XCTAssertEqual(
            IDELanguageServerHost.summary(statuses: ready, work: ["sourcekit-lsp": [indexing, preparing]]),
            "SourceKit-LSP: Indexing: 3 / 10 (30%) +1"
        )
    }

    func testAProjectThatCouldNotBePreparedStartsNoServerAndSaysSo() async throws {
        let marker = root.appendingPathComponent("launches")
        let box = LSPConnectionBox()
        let host = IDELanguageServerHost(trustDirectory: root)
        var definition = crashingServer(marker: marker)
        definition.prepare = { _ in .unavailable("xcodebuild was not found.") }
        host.trust(definition, root: root)
        await host.start(definition, connection: box, root: root)
        defer { host.stop() }

        XCTAssertEqual(host.statuses.map(\.phase), [.unprepared])
        XCTAssertEqual(host.summary, "fake: project not indexed")
        XCTAssertEqual(launchCount(marker), 0, "a server that would see one file at a time is not started")
        XCTAssertNil(box.current)
    }

    func testPreparationRunsAgainAtEveryLaunch() async throws {
        let marker = root.appendingPathComponent("launches")
        let counter = PrepareCounter()
        var definition = crashingServer(marker: marker)
        definition.prepare = { _ in counter.increment(); return .ready }
        let host = IDELanguageServerHost(trustDirectory: root)
        host.restartDelay = { _ in .seconds(30) }
        host.trust(definition, root: root)
        await host.start(definition, connection: LSPConnectionBox(), root: root)
        let first = counter.count
        host.stop()
        await host.start(definition, connection: LSPConnectionBox(), root: root)
        host.stop()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(counter.count, 2, "a restart regenerates what the server needs, so a reload shows up")
    }

    private final class PrepareCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    func testWorkOnlyShowsWhileTheServerIsReady() {
        typealias Status = IDELanguageServerHost.ServerStatus
        let work = ["sourcekit-lsp": [LSPWorkProgress(token: "i", title: "Indexing")]]
        for (phase, expected) in [
            (IDELanguageServerHost.Phase.starting, "SourceKit-LSP: starting"),
            (.restarting, "SourceKit-LSP: restarting"),
            (.untrusted, "SourceKit-LSP: not trusted"),
            (.unprepared, "SourceKit-LSP: project not indexed"),
        ] {
            let statuses = [Status(id: "sourcekit-lsp", name: "SourceKit-LSP", phase: phase)]
            XCTAssertEqual(IDELanguageServerHost.summary(statuses: statuses, work: work), expected)
        }
        XCTAssertNil(IDELanguageServerHost.summary(statuses: [], work: work), "no server, nothing to show")
    }

    func testACrashFallsBackToTheNativeTierAndRestarts() async throws {
        let marker = root.appendingPathComponent("launches")
        let box = LSPConnectionBox()
        let host = IDELanguageServerHost(trustDirectory: root)
        host.restartDelay = { _ in .milliseconds(40) }
        let definition = crashingServer(marker: marker)
        host.trust(definition, root: root)
        await host.start(definition, connection: box, root: root)

        let deadline = Date().addingTimeInterval(4)
        while (host.nativeFallbacks < 1 || launchCount(marker) < 2), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        host.stop()
        XCTAssertGreaterThanOrEqual(host.nativeFallbacks, 1, "a crash clears the semantic connection")
        XCTAssertGreaterThanOrEqual(launchCount(marker), 2, "the host starts the server again")
        XCTAssertNil(box.current)
    }

    func testTrustingThroughThePromptLaunchesAndDecliningDoesNot() async throws {
        let marker = root.appendingPathComponent("prompted")
        let box = LSPConnectionBox()
        let host = IDELanguageServerHost(trustDirectory: root)
        let definition = crashingServer(marker: marker)
        host.requestTrust = { _, _ in true }
        await host.start(definition, connection: box, root: root)
        let deadline = Date().addingTimeInterval(2)
        while launchCount(marker) < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        host.stop()
        XCTAssertGreaterThanOrEqual(launchCount(marker), 1)
        XCTAssertTrue(host.isTrusted(definition, root: root))

        let declinedMarker = root.appendingPathComponent("declined")
        let declined = crashingServer(marker: declinedMarker)
        declinedHost: do {
            let quiet = IDELanguageServerHost(trustDirectory: root.appendingPathComponent("other-trust", isDirectory: true))
            quiet.requestTrust = { _, _ in false }
            let quietBox = LSPConnectionBox()
            await quiet.start(declined, connection: quietBox, root: root)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(launchCount(declinedMarker), 0)
            XCTAssertNil(quietBox.current)
            XCTAssertEqual(quiet.statuses.first?.phase, .untrusted)
            quiet.stop()
        }
    }

    func testAnUntrustedFolderDoesNotLaunch() async throws {
        let marker = root.appendingPathComponent("launches")
        let box = LSPConnectionBox()
        let host = IDELanguageServerHost(trustDirectory: root)
        let definition = crashingServer(marker: marker)
        await host.start(definition, connection: box, root: root)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(launchCount(marker), 0)
        XCTAssertNil(box.current)
        XCTAssertEqual(host.statuses.first?.phase, .untrusted)
        host.stop()
    }

    func testTheWorkspaceDeallocatesWhileAServerIsRunning() async throws {
        weak var weakWorkspace: IDEWorkspace?
        let marker = root.appendingPathComponent("sleeps")
        do {
            let workspace = IDEWorkspace()
            weakWorkspace = workspace
            let definition = IDELanguageServerDefinition(
                id: "sleep",
                configuration: LSPLanguageConfiguration(
                    name: "sleep", languageIdentifiers: ["swift"], diagnosticSource: .sourceKitLSP
                ),
                discover: { _ in IDEServerExecutable(url: URL(fileURLWithPath: "/bin/sh")) },
                arguments: { _ in ["-c", "echo x >> \(marker.path); sleep 30"] },
                trustFile: "sleep-trust.json"
            )
            workspace.languageServerHost.trust(definition, root: root)
            await workspace.languageServerHost.start(
                definition, connection: LSPConnectionBox(), root: root
            )
            let deadline = Date().addingTimeInterval(2)
            while launchCount(marker) < 1, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertGreaterThanOrEqual(launchCount(marker), 1)
            workspace.teardown()
        }
        for _ in 0..<40 where weakWorkspace != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(weakWorkspace, "a running language server keeps the closed window's workspace")
    }

    /// The window hands the host its workspace, and the host tells the server about the open documents:
    /// a real `sourcekit-lsp` answers from the editor's buffer, which differs from the file on disk.
    /// Without the sync it answers every request about the file with "No language service found".
    func testTheHostSendsTheOpenBufferToARealSourceKit() async throws {
        let definition = IDESourceKitServer.definition()
        let context = IDEServerDiscoveryContext(root: root, environment: ProcessInfo.processInfo.environment)
        guard await definition.discover(context) != nil else { throw XCTSkip("No sourcekit-lsp on this machine") }

        let sources = root.appendingPathComponent("Sources/Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = sources.appendingPathComponent("Box.swift")
        try "public struct Box { public var width = 1 }\n".write(to: file, atomically: true, encoding: .utf8)

        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let buffer = Document(
            url: file, displayName: "Box.swift",
            contentSnapshot: TextSnapshot(version: 0, text: "public struct Box { public var width = 1; public var height = 2 }\n"),
            selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "swift"
        )
        let workspace = Workspace()
        await workspace.openDocument(buffer)

        let box = LSPConnectionBox()
        let host = IDELanguageServerHost(trustDirectory: root.appendingPathComponent("trust", isDirectory: true))
        host.documentWorkspace = workspace
        host.trust(definition, root: root)
        await host.start(definition, connection: box, root: root)
        defer { host.stop() }

        var members: [String] = []
        let deadline = Date().addingTimeInterval(30)
        while !members.contains("height"), Date() < deadline {
            if let client = box.current as? LanguageServerClient,
               let symbols = try? await client.requestDocumentSymbols(for: buffer) {
                func names(_ items: [LSPOutlineSymbol]) -> [String] { items.flatMap { [$0.name] + names($0.children) } }
                members = names(symbols)
            }
            if !members.contains("height") { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        XCTAssertTrue(members.contains("height"), "the server never saw the buffer; its outline was \(members)")
    }

    private func crashingServer(marker: URL) -> IDELanguageServerDefinition {
        IDELanguageServerDefinition(
            id: "fake",
            configuration: LSPLanguageConfiguration(
                name: "fake", languageIdentifiers: ["swift"], diagnosticSource: .sourceKitLSP
            ),
            discover: { _ in IDEServerExecutable(url: URL(fileURLWithPath: "/bin/sh")) },
            arguments: { _ in ["-c", "echo x >> \(marker.path); exit 1"] },
            trustFile: "fake-trust.json"
        )
    }

    private func launchCount(_ marker: URL) -> Int {
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }
}
