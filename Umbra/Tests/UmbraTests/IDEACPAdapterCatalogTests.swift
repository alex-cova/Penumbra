import Foundation
import XCTest
@testable import Umbra

final class IDEACPAdapterCatalogTests: XCTestCase {
    func testEntriesAreWellFormedAndMatchThePresets() {
        let ids = IDEACPAdapterCatalog.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique")
        XCTAssertEqual(ids, ["codex-acp", "claude-agent-acp", "gemini", "opencode"])
        for entry in IDEACPAdapterCatalog.entries {
            XCTAssertFalse(entry.name.isEmpty)
            XCTAssertFalse(entry.provider.isEmpty)
            XCTAssertFalse(entry.authHint.isEmpty)
            XCTAssertFalse(entry.strategies.isEmpty)
            XCTAssertNotNil(IDEACPRegistry.preset(id: entry.presetID), "\(entry.id) has a preset")
            XCTAssertEqual(IDEACPAdapterCatalog.entry(presetID: entry.presetID)?.id, entry.id)
        }
    }

    func testCodexAndClaudeAreManagedNpmPackagesFromTheirOfficialRepositories() throws {
        let codex = try XCTUnwrap(IDEACPAdapterCatalog.entry(id: "codex-acp")?.npm)
        let claude = try XCTUnwrap(IDEACPAdapterCatalog.entry(id: "claude-agent-acp")?.npm)
        XCTAssertEqual(codex.package, "@agentclientprotocol/codex-acp")
        XCTAssertEqual(claude.package, "@agentclientprotocol/claude-agent-acp")
        XCTAssertEqual(codex.repository, "https://github.com/agentclientprotocol/codex-acp")
        XCTAssertEqual(claude.repository, "https://github.com/agentclientprotocol/claude-agent-acp")
        XCTAssertEqual(codex.trustedPublisher, "github")
        XCTAssertEqual(claude.trustedPublisher, "github")
        XCTAssertEqual(IDEACPAdapterCatalog.managedEntries.map(\.id), ["codex-acp", "claude-agent-acp"])
    }

    func testNativeCLIsAreDetectedNeverInstalled() throws {
        let gemini = try XCTUnwrap(IDEACPAdapterCatalog.entry(id: "gemini"))
        let opencode = try XCTUnwrap(IDEACPAdapterCatalog.entry(id: "opencode"))
        XCTAssertFalse(gemini.isManaged)
        XCTAssertFalse(opencode.isManaged)
        XCTAssertEqual(gemini.kind, .nativeCLI(command: "gemini", args: ["--acp"]))
        XCTAssertEqual(opencode.kind, .nativeCLI(command: "opencode", args: ["acp"]))
        XCTAssertEqual(IDEACPAdapterCatalog.custom.kind, .custom)
        XCTAssertFalse(IDEACPAdapterCatalog.custom.isManaged)
    }

    func testNoVersionNumberIsHardCodedAndNpxNeverAppears() {
        for entry in IDEACPAdapterCatalog.entries + [IDEACPAdapterCatalog.custom] {
            let text = String(describing: entry)
            XCTAssertNil(text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression), "\(entry.id) pins a version: \(text)")
            XCTAssertFalse(text.contains("npx"))
        }
    }
}
