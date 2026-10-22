import Foundation
import Testing
@testable import AgentKit

@Suite struct ToolCostTests {
    private let tool = ToolDefinition(
        name: "read_file", description: String(repeating: "d", count: 100),
        parameters: [ToolParameter("path", .string, "The path")])

    @Test func charactersCountNameDescriptionAndSchema() {
        let schema = (try? tool.schema(strict: false).serialized().count) ?? 0
        #expect(ToolCost.characters(of: tool) == 9 + 100 + schema)
        #expect(schema > 0)
    }

    @Test func eachProviderHasItsOwnFactorAndTheCostScalesWithSize() {
        #expect(ToolCost.charactersPerToken(provider: "anthropic") < ToolCost.charactersPerToken(provider: "ollama"))
        #expect(ToolCost.charactersPerToken(provider: "ollama") < ToolCost.charactersPerToken(provider: "openai-responses"))
        #expect(ToolCost.charactersPerToken(provider: "responses") == ToolCost.charactersPerToken(provider: "openai-chat"))
        #expect(ToolCost.charactersPerToken(provider: "something-new") == 3.0)
        #expect(ToolCost.tokens(of: tool, provider: "anthropic") > ToolCost.tokens(of: tool, provider: "responses"))
        #expect(ToolCost.tokens(of: [tool, tool], provider: "anthropic") >= 2 * ToolCost.tokens(of: tool, provider: "anthropic") - 1)
        #expect(ToolCost.tokens(ofText: "", provider: "anthropic") == 0)
    }

    @Test func aRawSchemaCountsAsSent() {
        let big = ToolDefinition(name: "t", description: "d", rawSchema: ["type": "object", "properties": ["a": ["type": "string", "description": .string(String(repeating: "x", count: 500))]]])
        #expect(ToolCost.characters(of: big) > 500)
    }
}
