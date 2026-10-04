import AgentKit
import Foundation
import MLXLMCommon
import Testing
@testable import AgentKitMLX

@Suite struct MLXConversationTests {
    @Test func aTrailingUserMessageIsPendingAndEverythingBeforeItIsHistory() throws {
        let items: [ConversationItem] = [.user("a"), .assistant("b"), .user("c")]
        let split = try #require(MLXConversation.split(items))
        #expect(split.history == [.user("a"), .assistant("b")])
        #expect(split.pending == [.user("c")])
    }

    @Test func aTurnsToolOutputsArePendingTogether() throws {
        let items: [ConversationItem] = [
            .user("go"), .toolCall(id: "1", name: "grep", arguments: "{}"), .toolCall(id: "2", name: "glob", arguments: "{}"),
            .toolOutput(callID: "1", output: "x"), .toolOutput(callID: "2", output: "y"),
        ]
        let split = try #require(MLXConversation.split(items))
        #expect(split.history.count == 3)
        #expect(split.pending == [.toolOutput(callID: "1", output: "x"), .toolOutput(callID: "2", output: "y")])
    }

    @Test func historyThatDoesNotEndInSomethingAnswerableIsRefused() {
        #expect(MLXConversation.split([]) == nil)
        #expect(MLXConversation.split([.user("a"), .assistant("b")]) == nil)
        #expect(MLXConversation.split([.user("a"), .toolCall(id: "1", name: "t", arguments: "{}")]) == nil)
    }

    @Test func messagesGroupAnAssistantsTextAndCallsAndDropForeignItems() throws {
        let items: [ConversationItem] = [
            .user("go"),
            .opaque(OpaqueItem(provider: "openai-responses", payload: ["type": "reasoning"])),
            .assistant("Looking."),
            .toolCall(id: "c1", name: "read_file", arguments: #"{"path":"A.java","offset":3}"#),
            .toolOutput(callID: "c1", output: "contents"),
            .assistant("Done."),
        ]
        let messages = MLXConversation.messages(items)
        #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(messages[1].content == "Looking.")
        let calls = MLXTestSupport.calls(in: try #require(messages[1].tool))
        #expect(calls.count == 1 && calls[0].function.name == "read_file" && calls[0].id == "c1")
        #expect(MLXBridge.argumentsText(calls[0]) == #"{"offset":3,"path":"A.java"}"#, "arguments round-trip as key-sorted JSON")
        #expect(messages[2].content == "contents")
    }

    @Test func aCallWithNoTextIsAnAssistantMessageWithEmptyContent() {
        let messages = MLXConversation.messages([.user("x"), .toolCall(id: "c", name: "t", arguments: "{}")])
        #expect(messages.count == 2 && messages[1].role == .assistant && messages[1].content.isEmpty)
    }
}

@Suite struct MLXBridgeTests {
    private let tool = ToolDefinition(name: "read_file", description: "Read a file.", parameters: [
        ToolParameter("path", .string, "Path."), ToolParameter("offset", .integer, "Start.", optional: true),
    ])

    @Test func toolsAreRenderedAsOpenAIFunctionSpecs() throws {
        let specs = try #require(MLXBridge.toolSpecs([tool]))
        #expect(specs.count == 1)
        #expect(specs[0]["type"] as? String == "function")
        let function = try #require(specs[0]["function"] as? [String: any Sendable])
        #expect(function["name"] as? String == "read_file")
        let parameters = try #require(function["parameters"] as? [String: any Sendable])
        #expect(parameters["type"] as? String == "object")
        #expect((parameters["required"] as? [any Sendable])?.compactMap { $0 as? String } == ["path"], "optional parameters stay optional for local models")
        #expect(parameters["additionalProperties"] == nil)
        let properties = try #require(parameters["properties"] as? [String: any Sendable])
        #expect(Set(properties.keys) == ["path", "offset"])
        #expect(MLXBridge.toolSpecs([]) == nil)
    }

    @Test func specsSerializeToJSONThatTemplatesCanRead() throws {
        let specs = try #require(MLXBridge.toolSpecs([tool]))
        let data = try JSONSerialization.data(withJSONObject: specs)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""name":"read_file""#) && text.contains(#""type":"function""#))
    }
}
