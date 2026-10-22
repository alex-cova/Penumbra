import AgentKit
import Foundation
import XCTest
@testable import Umbra

@MainActor
final class IDEAgentAgentCatalogTests: XCTestCase {
    func testTheProjectsAgentsAreOfferedBeforeTheUsersAndGeneralIsAlwaysThere() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-agents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project/.umbra/agents")
        let claude = root.appendingPathComponent("project/.claude/agents")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try "---\ndescription: from umbra\n---\nA".write(to: project.appendingPathComponent("reviewer.md"), atomically: true, encoding: .utf8)
        try "---\ndescription: from claude\n---\nB".write(to: claude.appendingPathComponent("reviewer.md"), atomically: true, encoding: .utf8)
        try "---\ndescription: tests\nmode: edit\n---\nC".write(to: claude.appendingPathComponent("tester.md"), atomically: true, encoding: .utf8)

        let catalog = IDEAgentCommandCatalog(
            root: { root.appendingPathComponent("project") }, loadsUserFolders: { false }, home: nil, appSupport: nil)
        let agents = catalog.agentCatalog
        XCTAssertEqual(agents.agents.map(\.name), ["general", "reviewer", "tester"])
        XCTAssertEqual(agents.agent(named: "reviewer")?.description, "from umbra")
        XCTAssertEqual(agents.agent(named: "tester")?.editsFiles, true)
    }

    func testWithNoFoldersOnlyGeneralIsOffered() {
        let catalog = IDEAgentCommandCatalog(root: { nil }, loadsUserFolders: { false }, home: nil, appSupport: nil)
        XCTAssertEqual(catalog.agentCatalog.agents.map(\.name), ["general"])
    }
}
