import Foundation
import Testing
@testable import AgentKit

/// Opt-in: how many real input tokens a provider charges per character of tool definition.
@Suite(.serialized, .enabled(if: Eval.enabled)) struct ToolCostCalibrationTests {
    private func inputTokens(_ model: Eval.Model, tools: [ToolDefinition], system: String) async throws -> Int {
        let request = LLMRequest(
            model: model.id, system: system, items: [.user("Reply with the single word: ok")], tools: tools,
            reasoningEffort: nil, maxOutputTokens: 64)
        let events = try await collect(model.make().stream(request))
        for case .usage(let usage) in events where usage.inputTokens > 0 { return usage.inputTokens }
        return 0
    }

    @Test func calibrate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calib-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = await evalFilesystemHub(directory: dir)
        let builtIn = evalBuiltInTools().map(\.definition)
        let mcp = await hub.tools.map(\.definition)
        let system = SystemPrompt.make(projectRoot: dir.path)

        func characters(_ definitions: [ToolDefinition]) -> Int {
            definitions.reduce(0) { $0 + $1.name.count + $1.description.count + ((try? $1.schema(strict: false).serialized().count) ?? 0) }
        }
        for model in Eval.models(["haiku-5.5", "gpt-4.1-mini", "bonsai-2"]) {
            let none = try await inputTokens(model, tools: [], system: system)
            let some = try await inputTokens(model, tools: builtIn, system: system)
            let all = try await inputTokens(model, tools: builtIn + mcp, system: system)
            let builtInChars = characters(builtIn), mcpChars = characters(mcp)
            print("CALIB \(model.label): system only \(none) tok (\(system.count) chars) | +\(builtIn.count) built-in: +\(some - none) tok for \(builtInChars) chars = \(String(format: "%.2f", Double(builtInChars) / Double(max(1, some - none)))) chars/tok | +\(mcp.count) MCP: +\(all - some) tok for \(mcpChars) chars = \(String(format: "%.2f", Double(mcpChars) / Double(max(1, all - some)))) chars/tok")
        }
        await hub.close()
    }
}
