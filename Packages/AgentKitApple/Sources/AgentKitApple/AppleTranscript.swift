import AgentKit
import Foundation
import FoundationModels

/// What a rebuilt session starts from: the history as the framework's transcript, and the text that
/// is sent as the prompt.
struct AppleTranscriptPlan {
    var entries: [Transcript.Entry]
    var prompt: String
}

/// Maps AgentKit's conversation onto `Transcript` entries. Pure, so the mapping is tested without a model.
enum AppleTranscript {
    /// `nil` when the items do not end in something the model can answer (a user message, or tool outputs).
    static func plan(system: String, tools: [ToolDefinition], items: [ConversationItem]) -> AppleTranscriptPlan? {
        guard let last = items.last else { return nil }
        var earlier: [ConversationItem]
        let prompt: String
        switch last {
        case .user(let text):
            earlier = Array(items.dropLast())
            prompt = text
        case .toolOutput:
            // The calls and their outputs go back as one message: a transcript that ends in tool output
            // has nothing to answer, and a rebuilt one never saw the calls run.
            var start = items.count
            while start > 0, case .toolOutput = items[start - 1] { start -= 1 }
            let outputs = Array(items[start...])
            var callStart = start
            while callStart > 0, case .toolCall = items[callStart - 1] { callStart -= 1 }
            earlier = Array(items[..<callStart])
            prompt = resultsPrompt(calls: Array(items[callStart..<start]), outputs: outputs)
        default:
            return nil
        }
        var entries: [Transcript.Entry] = []
        let definitions = tools.compactMap { tool -> Transcript.ToolDefinition? in
            guard let schema = try? AppleToolSchema.generationSchema(for: tool) else { return nil }
            return Transcript.ToolDefinition(name: tool.name, description: tool.description, parameters: schema)
        }
        if !system.isEmpty || !definitions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(segments: [text(system)], toolDefinitions: definitions)))
        }
        entries += history(earlier)
        return AppleTranscriptPlan(entries: entries, prompt: prompt)
    }

    private static func text(_ content: String) -> Transcript.Segment { .text(Transcript.TextSegment(content: content)) }

    private static func history(_ items: [ConversationItem]) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []
        var names: [String: String] = [:]
        var calls: [Transcript.ToolCall] = []
        func flushCalls() {
            guard !calls.isEmpty else { return }
            entries.append(.toolCalls(Transcript.ToolCalls(calls)))
            calls = []
        }
        for item in items {
            switch item {
            case .user(let value):
                flushCalls()
                entries.append(.prompt(Transcript.Prompt(segments: [text(value)])))
            case .assistant(let value):
                flushCalls()
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [text(value)])))
            case .toolCall(let id, let name, let arguments):
                names[id] = name
                let content = (try? GeneratedContent(json: arguments)) ?? (try? GeneratedContent(json: "{}")) ?? GeneratedContent("")
                calls.append(Transcript.ToolCall(id: id, toolName: name, arguments: content))
            case .toolOutput(let callID, let output):
                flushCalls()
                entries.append(.toolOutput(Transcript.ToolOutput(id: callID, toolName: names[callID] ?? "tool", segments: [text(output)])))
            case .opaque:
                continue
            }
        }
        flushCalls()
        return entries
    }

    private static func resultsPrompt(calls: [ConversationItem], outputs: [ConversationItem]) -> String {
        var names: [String: String] = [:]
        for case .toolCall(let id, let name, _) in calls { names[id] = name }
        var lines = ["Results of the tools you called:"]
        for case .toolOutput(let callID, let output) in outputs {
            lines.append("[\(names[callID] ?? "tool")]\n\(output)")
        }
        lines.append("Carry on with the task.")
        return lines.joined(separator: "\n\n")
    }
}
