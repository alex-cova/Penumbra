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
}
