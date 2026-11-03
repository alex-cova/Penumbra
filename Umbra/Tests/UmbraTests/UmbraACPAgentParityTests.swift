import AgentKit
import Foundation
import XCTest
import UmbraAgentSupport

/// Phase 3 test (docs/harness/agent-harness-6.md): the session an ACP agent serves the way
/// `UmbraACP` builds it — shared provider setup, shared permission files, the
/// host-independent `run_command` — round-trips a command approval through
/// `session/request_permission`, and a denial stops the tool.
final class UmbraACPAgentParityTests: XCTestCase {
    private struct TestHost: UmbraAgentCommandHost {
        var projectRoot: URL
        func commandEnvironment() async -> [String: String] {
            AgentCommandEnvironment.make(javaHome: nil)
        }
        func showCommand(id: UUID, title: String, line: String?) {}
    }

    private func rig(
        turns: [MockTurn], decisions: @escaping @Sendable (ApprovalRequest) -> ApprovalDecision,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (events: [AgentEvent], ran: Bool) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-acp-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (clientTransport, agentTransport) = ACPInMemoryTransport.pair()
        let endpoint = ACPAgentEndpoint(transport: agentTransport) { request in
            let sessionRoot = URL(fileURLWithPath: request.cwd)
            var tools: [any AgentTool] = ReadOnlyTools.all() + EditingTools.all()
            tools.append(UmbraAgentRunCommandTool(host: TestHost(projectRoot: sessionRoot)))
            tools += [TodoTool(), AskUserTool(), ExitPlanModeTool()]
            return AgentSession(
                client: MockLLMClient(turns: turns), tools: tools,
                workspace: DiskAgentWorkspace(root: sessionRoot),
                configuration: AgentConfiguration(
                    model: "mock", mode: .acceptEdits,
                    permissions: IDEAgentPermissionFiles.load(projectRoot: sessionRoot, appFile: nil),
                    shapeToolOutput: { IDEAgentOutputScrubber.shape($0) }),
                history: request.history,
                totalUsage: request.totalUsage,
                sessionID: request.sessionID ?? UUID())
        }
        let task = Task { await endpoint.run() }
        defer { task.cancel() }
        let client = ACPClientSession(transport: clientTransport, cwd: root.path)
        var events: [AgentEvent] = []
        var sawOutput = false
        for await event in await client.send("go") {
            events.append(event)
            switch event {
            case .approvalRequested(let request):
                await client.resolveApproval(callID: request.callID, decision: decisions(request))
            case .toolCallFinished(_, let name, let output) where name == "run_command":
                sawOutput = output.text.contains("acp-ok")
            default:
                break
            }
        }
        await endpoint.stop()
        return (events, sawOutput)
    }

    func testCommandApprovalRoundTripsAndRuns() async throws {
        let (events, ran) = try await rig(
            turns: [
                .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"echo acp-ok","reason":"probe"}"#)),
                .text("done"),
            ],
            decisions: { _ in .approve })
        XCTAssertTrue(ran, "the approved command runs and its output reaches the transcript")
        XCTAssertEqual(events.last, .runEnded(.completed))
    }

    func testDeniedCommandDoesNotRun() async throws {
        let (events, ran) = try await rig(
            turns: [
                .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"echo acp-ok","reason":"probe"}"#)),
                .text("skipped"),
            ],
            decisions: { _ in .deny(note: nil) })
        XCTAssertFalse(ran, "a denied command never runs")
        XCTAssertEqual(events.last, .runEnded(.completed))
    }
}
