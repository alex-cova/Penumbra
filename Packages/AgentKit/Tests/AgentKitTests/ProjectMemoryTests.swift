import Foundation
import Testing
@testable import AgentKit

private func memoryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-memory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct FetchTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(name: "fetch", description: "probe", parameters: [])
    }

    var risk: ToolRisk { .read }
    var honorsDenyRules: Bool { true }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        "something from elsewhere"
    }
}

@Suite struct ProjectMemoryTests {
    @Test func loadReadsWhatWasAppended() throws {
        let directory = try memoryDirectory()
        #expect(try ProjectMemory.append("the build needs Java 21", at: directory, date: "2026-10-18"))
        #expect(ProjectMemory.load(at: directory) == "2026-10-18: the build needs Java 21")
    }

    @Test func theCapKeepsTheNewestEntries() throws {
        let directory = try memoryDirectory()
        for index in 0..<400 {
            _ = try ProjectMemory.append("fact number \(index)", at: directory, date: "2026-10-18")
        }
        let loaded = try #require(ProjectMemory.load(at: directory))
        #expect(loaded.utf8.count <= ProjectMemory.byteLimit)
        #expect(loaded.contains("fact number 399"), "the newest entry survives")
        #expect(!loaded.contains("fact number 0"), "the oldest entries are dropped first")
    }

    @Test func symlinksAreRefused() throws {
        let directory = try memoryDirectory()
        let real = directory.appendingPathComponent("real.md")
        try "2026-10-18: elsewhere".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(ProjectMemory.fileName), withDestinationURL: real)
        #expect(ProjectMemory.load(at: directory) == nil)
    }

    @Test func appendPersistsADatedLine() throws {
        let directory = try memoryDirectory()
        #expect(try ProjectMemory.append("ships on Fridays", at: directory, date: "2026-10-18"))
        let text = try String(contentsOf: ProjectMemory.url(in: directory), encoding: .utf8)
        #expect(text.contains("2026-10-18: ships on Fridays"))
        let permissions = try FileManager.default.attributesOfItem(atPath: ProjectMemory.url(in: directory).path)
        #expect((permissions[.posixPermissions] as? Int) == 0o600)
    }

    @Test func duplicatesAreIgnored() throws {
        let directory = try memoryDirectory()
        #expect(try ProjectMemory.append("same fact", at: directory, date: "2026-10-18"))
        #expect(!(try ProjectMemory.append("same fact", at: directory, date: "2026-10-19")),
                "the fact is remembered whatever day it was saved")
        let lines = try String(contentsOf: ProjectMemory.url(in: directory), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 1)
    }

    @Test func theLiveRequestBytesStayTheSameAfterAWrite() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let directory = try memoryDirectory()
        let client = MockLLMClient(turns: [
            .toolCalls((id: "m1", name: "remember", arguments: #"{"text":"new fact"}"#)),
            .text("saved"),
        ])
        let agent = AgentSession(
            client: client,
            tools: [RememberTool(memoryDirectory: directory, today: { "2026-10-18" })],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m",
                systemPrompt: SystemPrompt.make(projectRoot: project.root.path, memory: "2026-10-18: old fact")))
        for await _ in await agent.send("go") {}
        #expect(client.requests.count == 2)
        #expect(client.requests[0].system == client.requests[1].system,
                "memory loads at session start; a write shows from the next session on")
    }

    @Test func anUntrustedRunAsksBeforeSaving() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let directory = try memoryDirectory()
        let client = MockLLMClient(turns: [
            .toolCalls((id: "f1", name: "fetch", arguments: "{}")),
            .toolCalls((id: "m1", name: "remember", arguments: #"{"text":"the docs say X"}"#)),
            .text("saved"),
        ])
        let agent = AgentSession(
            client: client,
            tools: [FetchTool(), RememberTool(memoryDirectory: directory, today: { "2026-10-18" })],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
        var approvals: [ApprovalRequest] = []
        for await event in await agent.send("go") {
            if case .approvalRequested(let request) = event {
                approvals.append(request)
                await agent.resolveApproval(callID: request.callID, decision: .approve)
            }
        }
        #expect(approvals.map(\.toolName) == ["remember"])
        #expect(ProjectMemory.load(at: directory)?.contains("the docs say X") == true)
        expectEveryCallAnswered(await agent.items)
    }

    @Test func aCleanRunSavesWithoutAsking() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let directory = try memoryDirectory()
        let probe = Probe()
        let client = MockLLMClient(turns: [
            .toolCalls((id: "r1", name: "look", arguments: #"{"n":1}"#)),
            .toolCalls((id: "m1", name: "remember", arguments: #"{"text":"plain fact"}"#)),
            .text("saved"),
        ])
        let agent = AgentSession(
            client: client,
            tools: [ProbeTool(name: "look", probe: probe), RememberTool(memoryDirectory: directory, today: { "2026-10-18" })],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
        var asked = false
        for await event in await agent.send("go") {
            if case .approvalRequested = event { asked = true }
        }
        #expect(!asked, "no rules and no untrusted content: the call applies")
        #expect(ProjectMemory.load(at: directory)?.contains("plain fact") == true)
    }

    @Test func theShaperRedactsBeforeTheLineIsStored() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let directory = try memoryDirectory()
        let client = MockLLMClient(turns: [
            .toolCalls((id: "m1", name: "remember", arguments: #"{"text":"the key is hunter2"}"#)),
            .text("saved"),
        ])
        let agent = AgentSession(
            client: client,
            tools: [RememberTool(memoryDirectory: directory, today: { "2026-10-18" })],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m",
                shapeToolOutput: { $0.text.replacingOccurrences(of: "hunter2", with: "[redacted]") }))
        for await _ in await agent.send("go") {}
        let stored = ProjectMemory.load(at: directory) ?? ""
        #expect(stored.contains("[redacted]"))
        #expect(!stored.contains("hunter2"))
    }

    @Test func rememberIsNotOfferedInPlanMode() {
        let tool = RememberTool(memoryDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(!tool.isOffered(in: .plan))
        #expect(tool.isOffered(in: .acceptEdits))
    }
}
