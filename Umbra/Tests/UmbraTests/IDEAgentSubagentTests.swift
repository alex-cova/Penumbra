import AgentKit
import AgentKitMLX
import Foundation
import JavaIntelligence
import LocalModelStore
import XCTest
@testable import Umbra

/// Subagents with real work: a child's command asks on a card labelled with its agent, and
/// stopping one child leaves the parent running.
@MainActor
final class IDEAgentSubagentTests: XCTestCase {
    private var project: URL!
    private var hosts: [CommandHost] = []

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-sub-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project)
    }

    private func makeController(_ turns: [MockTurn]) -> IDEAgentController {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let host = CommandHost(root: project)
        hosts.append(host)
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: host)
        return controller
    }

    private func makeReactiveController(_ react: @escaping @Sendable (LLMRequest) -> MockTurn) -> IDEAgentController {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = ReactiveLLMClient(react)
        let host = CommandHost(root: project)
        hosts.append(host)
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: host)
        return controller
    }

    private func waitFor(_ message: String, timeout: Double = 15, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func taskEntry(_ controller: IDEAgentController) -> IDEAgentEntry? {
        controller.entries.first { entry in
            if case .toolCall(let name) = entry.kind, name == "task" { true } else { false }
        }
    }

    func testAChildCommandShowsAnApprovalCardLabelledWithItsAgent() async throws {
        let taskArgs = #"{"agent":"general","description":"say hi","prompt":"run echo hi"}"#
        let controller = makeController([
            .toolCalls((id: "t1", name: "task", arguments: taskArgs)),
            .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"echo hi","reason":"a test"}"#)),
            .text("the child ran it"),
            .text("done"),
        ])
        controller.draft = "delegate it"
        controller.send()
        await waitFor("the child's approval card appears") { self.taskEntry(controller)?.approval != nil }

        let request = try XCTUnwrap(taskEntry(controller)?.approval)
        XCTAssertTrue(request.title.hasPrefix("[general]"), "labelled with the agent, got \(request.title)")
        XCTAssertEqual(request.command, "echo hi")

        controller.decide(callID: request.callID, .approve)
        await waitFor("the run finishes") { !controller.isRunning }
        let entry = try XCTUnwrap(taskEntry(controller))
        XCTAssertNil(entry.approval)
        XCTAssertEqual(entry.approvalOutcome, "Approved")
        XCTAssertTrue(entry.output?.text.contains("the child ran it") == true)
        XCTAssertEqual(controller.entries.last?.text, "done")
    }

    func testStoppingAChildLeavesTheParentRunning() async throws {
        let taskArgs = #"{"agent":"general","description":"slow job","prompt":"take your time","background":true}"#
        let slow = MockTurn(
            [.textDelta("s"), .textDelta("l"), .textDelta("o"), .textDelta("w"), .finished(.completed)],
            delayPerEvent: .milliseconds(300))
        let controller = makeReactiveController { request in
            let names = Set(request.tools.map(\.name))
            if !names.contains("task") { return slow }
            let hasOutput = request.items.contains { if case .toolOutput = $0 { true } else { false } }
            if hasOutput { return .text("final answer") }
            return .toolCalls((id: "t1", name: "task", arguments: taskArgs))
        }
        controller.draft = "start it in the background"
        controller.send()
        await waitFor("the background child starts") { self.taskEntry(controller)?.output != nil }
        try? await Task.sleep(for: .milliseconds(200))

        controller.stopSubagentCall(callID: "t1")
        await waitFor("the run finishes") { !controller.isRunning }
        XCTAssertEqual(controller.entries.last?.text, "final answer", "the parent carries on after its child stops")
        XCTAssertFalse(
            controller.entries.contains { $0.text.contains("finished in the background") },
            "the stopped child files no report")
    }
}

/// Answers every request from a closure, so parent and child turns can share one client.
private final class ReactiveLLMClient: LLMClient, @unchecked Sendable {
    let providerID = "mock"
    let supportsDisabledToolChoice = false
    private let react: @Sendable (LLMRequest) -> MockTurn

    init(_ react: @escaping @Sendable (LLMRequest) -> MockTurn) { self.react = react }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        MockLLMClient(turns: [react(request)]).stream(request)
    }
}
