import AgentKit
import Foundation
import FoundationModels
import Testing
@testable import AgentKitApple

@Suite struct AppleToolSchemaTests {
    @Test func everyShapeAToolCanDeclareConverts() throws {
        let tool = ToolDefinition(name: "demo", description: "Demo", parameters: [
            ToolParameter("path", .string, "A path"),
            ToolParameter("count", .integer, "How many", optional: true),
            ToolParameter("ratio", .number, "A ratio", optional: true),
            ToolParameter("deep", .boolean, "Deep", optional: true),
            ToolParameter("names", .array(of: .string), "Names", optional: true),
            ToolParameter("mode", .enumeration(["a", "b"]), "Mode", optional: true),
        ])
        _ = try AppleToolSchema.generationSchema(for: tool)
    }

    @Test func aRawSchemaWithNestedObjectsAndUnknownShapesConverts() throws {
        let raw = try JSONValue(parsing: """
        {"type":"object","properties":{
          "filter":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]},
          "either":{"anyOf":[{"type":"string"},{"type":"integer"}]},
          "maybe":{"type":["string","null"]},
          "tags":{"type":"array","items":{"type":"object","properties":{"k":{"type":"string"}}}}
        },"required":["filter"]}
        """)
        _ = try AppleToolSchema.generationSchema(for: ToolDefinition(name: "mcp_demo", description: "x", rawSchema: raw))
    }

    @Test func aToolWithNoParametersConverts() throws {
        _ = try AppleToolSchema.generationSchema(for: ToolDefinition(name: "ping", description: "Ping"))
    }
}

@Suite struct AppleTranscriptTests {
    private let readFile = ToolDefinition(name: "read_file", description: "Reads", parameters: [ToolParameter("path", .string, "p")])

    @Test func aUserMessageIsThePromptAndTheRestIsHistory() throws {
        let plan = try #require(AppleTranscript.plan(
            system: "sys", tools: [readFile],
            items: [.user("a"), .assistant("b"), .toolCall(id: "1", name: "read_file", arguments: "{\"path\":\"x\"}"),
                    .toolOutput(callID: "1", output: "out"), .assistant("c"), .user("d")]))
        #expect(plan.prompt == "d")
        // instructions, prompt, response, tool calls, tool output, response
        #expect(plan.entries.count == 6)
        guard case .instructions(let instructions) = plan.entries[0] else { Issue.record("no instructions"); return }
        #expect(instructions.toolDefinitions.map(\.name) == ["read_file"])
        guard case .toolOutput(let output) = plan.entries[4] else { Issue.record("no tool output"); return }
        #expect(output.toolName == "read_file")
    }

    @Test func noSystemPromptAndNoToolsLeavesOutTheInstructions() throws {
        let plan = try #require(AppleTranscript.plan(system: "", tools: [], items: [.user("a")]))
        #expect(plan.entries.isEmpty)
        #expect(plan.prompt == "a")
    }

    @Test func otherProvidersItemsAreDropped() throws {
        let opaque = OpaqueItem(provider: "other", payload: .object([:]))
        let plan = try #require(AppleTranscript.plan(system: "", tools: [], items: [.user("a"), .opaque(opaque), .assistant("b"), .user("c")]))
        #expect(plan.entries.count == 2)
    }

    @Test func conversationsThatEndInAnAnswerCannotBeSent() {
        #expect(AppleTranscript.plan(system: "", tools: [], items: [.user("a"), .assistant("b")]) == nil)
        #expect(AppleTranscript.plan(system: "", tools: [], items: []) == nil)
    }
}

@Suite struct AppleErrorMappingTests {
    @Test func anLLMErrorPassesThrough() {
        guard case .fail(let error) = AppleErrorMapping.classify(LLMError.unauthorized, hadOutput: false) else {
            Issue.record("expected a failure"); return
        }
        #expect(error == .unauthorized)
    }

    @Test func anythingElseIsAnAPIErrorWithItsDescription() {
        struct Plain: LocalizedError { var errorDescription: String? { "boom" } }
        guard case .fail(let error) = AppleErrorMapping.classify(Plain(), hadOutput: true) else {
            Issue.record("expected a failure"); return
        }
        #expect(error == .api(message: "boom", code: nil))
    }
}

@Suite struct AppleContextFitTests {
    @Test func aPromptThatLeavesNoRoomForAnAnswerExceeds() {
        let big = String(repeating: "word ", count: 4_000)
        let request = LLMRequest(model: "m", items: [.user(big)])
        #expect(AppleContextFit.exceeds(request, window: 4_096))
        #expect(!AppleContextFit.exceeds(LLMRequest(model: "m", items: [.user("hi")]), window: 4_096))
        #expect(!AppleContextFit.exceeds(request, window: 0))
    }
}
