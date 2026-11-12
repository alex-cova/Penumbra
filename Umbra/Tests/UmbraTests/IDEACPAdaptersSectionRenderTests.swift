import AppKit
import SwiftUI
import XCTest
@testable import Umbra

/// Lays out the Adapters section and the approval sheet in a real window. Set `UMBRA_RENDER_DIR`
/// to also write PNGs of what they look like.
@MainActor
final class IDEACPAdaptersSectionRenderTests: XCTestCase {
    private var saved: IDEACPAdapterManager!
    private var root: ACPTestRoot!

    override func setUp() async throws {
        saved = IDEACPAdapterManager.shared
        root = try ACPTestRoot()
    }

    override func tearDown() async throws {
        IDEACPAdapterManager.shared = saved
        root.cleanUp()
    }

    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) async throws {
        let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 100)
        if let directory = ProcessInfo.processInfo.environment["UMBRA_RENDER_DIR"],
           let png = rep.representation(using: .png, properties: [:])
        {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        window.close()
    }

    private func manager(npm: ACPFakeNpm, fetcher: ACPFixtureFetcher) -> IDEACPAdapterManager {
        let registry = IDEACPNpmRegistry(fetcher: fetcher)
        let installer = IDEACPAdapterInstaller(environment: .init(
            store: root.store, registry: registry, npm: npm, locateNode: { acpFakeNode() },
            smokeTest: { _ in .connected(protocolVersion: 1, agentName: "Fake", loadSession: false) },
            freeBytes: { Int64.max }, hostArchitecture: "arm64", npmTimeout: .seconds(60), progressInterval: .milliseconds(50)))
        return IDEACPAdapterManager(
            store: root.store, registry: registry, installer: installer,
            defaults: UserDefaults(suiteName: "umbra.acp.render.\(UUID().uuidString)")!, isSandboxed: false)
    }

    func testTheSectionLaysOutWhenNothingIsInstalledAndWhenBusy() async throws {
        let fetcher = ACPFixtureFetcher()
        try fetcher.serve(package: "@agentclientprotocol/codex-acp", fixture: ACPFixtures.codex, version: "2.6.0")
        try fetcher.serve(package: "@agentclientprotocol/claude-agent-acp", fixture: ACPFixtures.claude, version: "0.106.0")
        let codex = try ACPFixtures.version(ACPFixtures.codex)
        let claude = try ACPFixtures.version(ACPFixtures.claude)
        let npm = ACPFakeNpm(packages: [
            .init(name: codex.name, version: codex.version, integrity: codex.dist.integrity!),
            .init(name: claude.name, version: claude.version, integrity: claude.dist.integrity!),
        ])
        let manager = manager(npm: npm, fetcher: fetcher)
        IDEACPAdapterManager.shared = manager
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.acp.render.settings.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        await manager.load()
        await manager.refreshNode()

        try await render(
            Form { IDEACPAdaptersSection(settings: settings, agent: nil) }.formStyle(.grouped),
            width: 640, height: 760, name: "adapters-empty")

        // Codex installed and behind, Claude mid-download.
        try acpInstallFakeAgent(root.store, version: "2.5.0", reply: "x")
        await manager.load()
        await manager.checkForUpdates()
        npm.hangsInInstall = true
        let proposal = try await manager.prepareInstall("claude-agent-acp")
        manager.install(proposal, settings: settings)
        _ = await acpWaitUntil { !npm.installCalls.isEmpty }
        try await render(
            Form { IDEACPAdaptersSection(settings: settings, agent: nil) }.formStyle(.grouped),
            width: 640, height: 820, name: "adapters-busy")
        manager.cancel("claude-agent-acp")
        _ = await acpWaitUntil { manager.states["claude-agent-acp"]?.phase == .notInstalled }

        try await render(
            IDEACPInstallApprovalSheet(proposal: proposal, onApprove: {}, onCancel: {}),
            width: 520, height: 420, name: "approval-sheet")
    }
}
