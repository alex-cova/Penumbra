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
