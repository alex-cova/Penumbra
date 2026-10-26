import Foundation
import Testing
@testable import AgentKit

private func helperTaskCall(_ agent: String = "scout", id: String = "t1") -> MockTurn {
    .toolCalls((id: id, name: "task", arguments: #"{"agent":"\#(agent)","description":"a job","prompt":"do it"}"#))
}

private func helperExploreCall(id: String = "x1") -> MockTurn {
    .toolCalls((id: id, name: "explore", arguments: #"{"task":"where is it?"}"#))
}

private func helperFinishedOutput(_ events: [AgentEvent], call: String) -> String? {
    for case .toolCallFinished(let id, _, let result) in events where id == call { return result.text }
    return nil
}

private func helperRun(_ agent: AgentSession, _ text: String = "go") async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await agent.send(text) { events.append(event) }
    return events
}

/// A read-only tool for children to call, so a test does not depend on the built-ins.
private struct HelperLookTool: AgentTool {
    var risk: ToolRisk { .read }
    var definition: ToolDefinition { ToolDefinition(name: "look", description: "look around") }
    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String { "nothing to see" }
}

/// Records whether it was asked for a summary (recognized by the summarizer's system prompt).
private final class SummarySpottingClient: LLMClient, @unchecked Sendable {
    let providerID = "mock"
    let inner: MockLLMClient
    let summaryText: String
    private let lock = NSLock()
    private var seen: [LLMRequest] = []

    init(turns: [MockTurn], summaryText: String) {
        inner = MockLLMClient(turns: turns)
        self.summaryText = summaryText
    }

    var summaryRequests: [LLMRequest] { lock.withLock { seen } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        guard request.system == ConversationSummary.systemPrompt else { return inner.stream(request) }
        lock.withLock { seen.append(request) }
        let text = summaryText
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(text))
            continuation.yield(.finished(.completed))
            continuation.finish()
        }
    }
}

@Suite struct HelperModelTests {
    @Test func modelParsesFromFrontmatterAndJoinsTheFingerprint() throws {
        let agent = try #require(AgentDefinition.parse(
            fileName: "scout.md",
            contents: "---\ndescription: looks around\nmodel: helper\n---\nLook.",
            source: ""))
        #expect(agent.model == "helper")
        let plain = try #require(AgentDefinition.parse(fileName: "plain.md", contents: "Just do it.", source: ""))
        #expect(plain.model == nil)
        #expect(AgentCatalog(agents: [agent]).fingerprint != AgentCatalog(agents: [AgentDefinition(
            name: "scout", description: "looks around", instructions: "Look.")]).fingerprint)
    }

    @Test func theTaskDescriptionNamesAnAgentWithAModel() {
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks", model: "helper")])
        let text = TaskTool(catalog: catalog).definition.description
        #expect(text.contains("- scout (read-only) [runs on model \"helper\"]: looks"))
        #expect(!TaskTool().definition.description.contains("[runs on model"))
    }

    @Test func aChildWithAModelUsesTheResolvedClientAndModel() async throws {
        let project = try TempProject(files: [:])
        let child = MockLLMClient(turns: [.text("found it")])
        let parent = MockLLMClient(turns: [helperTaskCall(), .text("done")])
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks", model: "helper")])
        let agent = AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + [TaskTool(catalog: catalog)],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "main", approval: .approveAll,
                makeChildClient: { key in
                    #expect(key == "helper")
                    return ChildClient(client: child, model: "helper-model", contextWindow: 4_096)
                }))
        let events = await helperRun(agent)
        #expect(events.last == .runEnded(.completed))
        #expect(child.requests.count == 1)
        #expect(child.requests.first?.model == "helper-model")
        let output = try #require(helperFinishedOutput(events, call: "t1"))
        #expect(output.contains("found it"))
        #expect(!output.contains("main model instead"))
    }

    @Test func anUnknownModelFallsBackToTheParentAndSaysSo() async throws {
        let project = try TempProject(files: [:])
        // Parent turn, the child's turn on the shared client, the parent's closing turn.
        let parent = MockLLMClient(turns: [helperTaskCall(), .text("child answer"), .text("done")])
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks", model: "nope")])
        let agent = AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + [TaskTool(catalog: catalog)],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "main", approval: .approveAll,
                makeChildClient: { _ in throw AgentConfigurationErrorForTests.unknown }))
        let events = await helperRun(agent)
        #expect(events.last == .runEnded(.completed))
        #expect(parent.requests.count == 3)
        let output = try #require(helperFinishedOutput(events, call: "t1"))
        #expect(output.contains("child answer"))
        #expect(output.contains("runs on the main model instead"))
    }

    @Test func aModelWithNoResolverFallsBackToo() async throws {
        let project = try TempProject(files: [:])
        let parent = MockLLMClient(turns: [helperTaskCall(), .text("child answer"), .text("done")])
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks", model: "helper")])
        let agent = AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + [TaskTool(catalog: catalog)],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "main", approval: .approveAll))
        let events = await helperRun(agent)
        #expect(events.last == .runEnded(.completed))
        let output = try #require(helperFinishedOutput(events, call: "t1"))
        #expect(output.contains("runs on the main model instead"))
    }

    @Test func exploreUsesTheHelperWhenSet() async throws {
        let project = try TempProject(files: [:])
        let child = MockLLMClient(turns: [.text("over there")])
        let parent = MockLLMClient(turns: [helperExploreCall(), .text("thanks")])
        let agent = AgentSession(
            client: parent,
            tools: [ExploreTool(model: "helper"), HelperLookTool()],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "main", approval: .approveAll,
                makeChildClient: { key in
                    #expect(key == "helper")
                    return ChildClient(client: child, model: "helper-model")
                }))
        let events = await helperRun(agent)
        #expect(events.last == .runEnded(.completed))
        #expect(child.requests.count == 1, "the research ran on the helper client")
        let output = try #require(helperFinishedOutput(events, call: "x1"))
        #expect(output.contains("over there"))
        #expect(!output.contains("main model instead"))
    }

    @Test func exploreFallsBackWithANoteWhenTheHelperIsUnavailable() async throws {
        let project = try TempProject(files: [:])
        let parent = MockLLMClient(turns: [helperExploreCall(), .text("child answer"), .text("thanks")])
        let agent = AgentSession(
            client: parent,
            tools: [ExploreTool(model: "helper"), HelperLookTool()],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "main", approval: .approveAll,
                makeChildClient: { _ in throw AgentConfigurationErrorForTests.unknown }))
        let events = await helperRun(agent)
        #expect(events.last == .runEnded(.completed))
        #expect(parent.requests.count == 3, "the research ran on the parent client")
        let output = try #require(helperFinishedOutput(events, call: "x1"))
        #expect(output.contains("runs on the main model instead"))
    }

    @Test func theNonCacheSummaryUsesTheSummaryClient() async throws {
        // About 610 tokens per output against a 2_500 window: stubs cannot help, so the oldest
        // part is summarized with one dedicated request.
        let parent = SummarySpottingClient(
            turns: (1...6).map { .toolCalls((id: "c\($0)", name: "bulk", arguments: #"{"n":\#($0)}"#)) } + [.text("done")],
            summaryText: "PARENT SUMMARY")
        let helper = SummarySpottingClient(turns: [], summaryText: "HELPER SUMMARY")
        let agent = AgentSession(
            client: parent,
            tools: [BulkToolForHelperTests(characters: 2_400)],
            workspace: try TempProject().workspace,
            configuration: AgentConfiguration(
                model: "main", systemPrompt: "sys", contextWindow: 2_500,
                summaryClient: ChildClient(client: helper, model: "helper-model")))
        let events = await helperRun(agent)
        #expect(events.last == .runEnded(.completed))
        #expect(!helper.summaryRequests.isEmpty)
        #expect(helper.summaryRequests.allSatisfy { $0.model == "helper-model" })
        #expect(parent.summaryRequests.isEmpty, "the parent never summarizes")
        let history = await agent.items
        #expect(history.contains { if case .user(let text) = $0 { text.contains("HELPER SUMMARY") } else { false } })
        #expect(!history.contains { if case .user(let text) = $0 { text.contains("PARENT SUMMARY") } else { false } })
    }
}

private enum AgentConfigurationErrorForTests: Error {
    case unknown
}

/// A read-only tool that answers with a fixed amount of text, to fill a window on purpose.
private struct BulkToolForHelperTests: AgentTool {
    let characters: Int
    var risk: ToolRisk { .read }
    var definition: ToolDefinition {
        ToolDefinition(name: "bulk", description: "bulk", parameters: [ToolParameter("n", .integer, "n", optional: true)])
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let n = try arguments.optionalInt("n") ?? 0
        return "output \(n)\n" + String(repeating: "x", count: characters)
    }
}
