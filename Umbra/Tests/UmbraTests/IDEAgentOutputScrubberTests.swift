import AgentKit
import Foundation
import XCTest

@testable import Umbra

final class IDEAgentOutputScrubberTests: XCTestCase {
    private func input(_ text: String, tool: String = "run_command", risk: ToolRisk = .command) -> ToolOutputShapingInput {
        ToolOutputShapingInput(toolName: tool, arguments: "", risk: risk, isError: false, text: text)
    }

    func testTokenShapesAreRedacted() {
        XCTAssertEqual(IDEAgentOutputScrubber.scrub("key AKIAIOSFODNN7EXAMPLE here"), "key [redacted] here")
        XCTAssertEqual(
            IDEAgentOutputScrubber.scrub("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 end"),
            "token [redacted] end")
        XCTAssertEqual(
            IDEAgentOutputScrubber.scrub("key sk-abcdefghijklmnopqrstuvwxyz0123456789 done"),
            "key [redacted] done")
        XCTAssertEqual(
            IDEAgentOutputScrubber.scrub("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----"),
            "[redacted]")
    }

    func testOrdinaryTextPassesThrough() {
        let text = "build succeeded in 12s; see task-abcdef for details"
        XCTAssertEqual(IDEAgentOutputScrubber.scrub(text), text)
    }

    func testOnlyCommandAndWebOutputIsScrubbed() {
        let leaked = "key AKIAIOSFODNN7EXAMPLE"
        XCTAssertEqual(IDEAgentOutputScrubber.shape(input(leaked)), "key [redacted]")
        XCTAssertEqual(IDEAgentOutputScrubber.shape(input(leaked, tool: "web_search", risk: .read)), "key [redacted]")
        XCTAssertEqual(IDEAgentOutputScrubber.shape(input(leaked, tool: "read_file", risk: .read)), leaked)
    }

    func testAMemoryLineIsScrubbedEvenThoughTheSessionPresentsItAsAnEdit() {
        let leaked = "deploy key AKIAIOSFODNN7EXAMPLE"
        XCTAssertEqual(IDEAgentOutputScrubber.shape(input(leaked, tool: "remember", risk: .edit)), "deploy key [redacted]")
        XCTAssertEqual(IDEAgentOutputScrubber.shape(input(leaked, tool: "edit_file", risk: .edit)), leaked, "other edits are untouched")
    }

    func testAKeyInARememberCallNeverReachesTheMemoryFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString)", isDirectory: true)
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: project)
        }
        let key = "sk-abcdefghijklmnopqrstuvwxyz0123456789"
        let client = MockLLMClient(turns: [
            MockTurn.toolCalls((id: "m", name: "remember", arguments: #"{"text":"The staging key is \#(key); use it for deploys."}"#)),
            .text("Noted."),
        ])
        let session = AgentSession(
            client: client, tools: [RememberTool(memoryDirectory: directory)], workspace: DiskAgentWorkspace(root: project),
            configuration: AgentConfiguration(
                model: "m", approval: .approveAll, shapeToolOutput: { IDEAgentOutputScrubber.shape($0) }))
        for await _ in await session.send("remember the staging key") {}

        let stored = try XCTUnwrap(ProjectMemory.load(at: directory))
        XCTAssertTrue(stored.contains("The staging key is [redacted]; use it for deploys."))
        XCTAssertFalse(stored.contains(key))
    }
}
