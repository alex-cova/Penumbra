import AgentKit
import Foundation
import MLXLMCommon

/// Converts between AgentKit's JSON and the dictionaries and values MLX works with.
enum MLXBridge {
    /// `[ToolDefinition]` as the OpenAI-shaped `tools` list chat templates read:
    /// `{type: function, function: {name, description, parameters}}`.
    static func toolSpecs(_ tools: [ToolDefinition]) -> [ToolSpec]? {
        guard !tools.isEmpty else { return nil }
        return tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": sendable(tool.schema(strict: false)),
                ] as [String: any Sendable],
            ]
        }
    }

    static func sendable(_ value: AgentKit.JSONValue) -> any Sendable {
        switch value {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let items): items.map(sendable)
        case .object(let object): object.mapValues(sendable)
        }
    }

    /// A call's arguments as the key-sorted JSON text the loop stores.
    static func argumentsText(_ call: ToolCall) -> String {
        guard let data = try? JSONEncoder().encode(call.function.arguments),
              let text = String(data: data, encoding: .utf8),
              let json = try? AgentKit.JSONValue(parsing: text),
              let sorted = try? json.serialized()
        else { return "{}" }
        return sorted
    }

    /// An MLX `ToolCall` rebuilt from what the loop stored, for replaying history to the template.
    static func toolCall(id: String, name: String, arguments: String) -> ToolCall {
        let object = (try? AgentKit.JSONValue(parsing: arguments))?.objectValue ?? [:]
        let arguments = object.mapValues(sendable)
        return ToolCall(function: .init(name: name, arguments: arguments), id: id)
    }
}

/// Splits a request's items into the part a session has already seen and what it must answer now,
/// and maps both to MLX chat messages.
enum MLXConversation {
    struct Split: Equatable {
        var history: [ConversationItem]
        /// The trailing user message, or the tool outputs of the last turn.
        var pending: [ConversationItem]
    }

    /// `nil` when the items do not end in something a model can answer.
    static func split(_ items: [ConversationItem]) -> Split? {
        guard let last = items.last else { return nil }
        switch last {
        case .user:
            return Split(history: Array(items.dropLast()), pending: [last])
        case .toolOutput:
            var start = items.count
            while start > 0, case .toolOutput = items[start - 1] { start -= 1 }
            return Split(history: Array(items[..<start]), pending: Array(items[start...]))
        default:
            return nil
        }
    }

    /// An assistant's text and the calls it made are one message; other providers' items are dropped.
    static func messages(_ items: [ConversationItem]) -> [Chat.Message] {
        var result: [Chat.Message] = []
        var text: String?
        var calls: [ToolCall] = []
        func flush() {
            guard text != nil || !calls.isEmpty else { return }
            result.append(.assistant(text ?? "", toolCalls: calls.isEmpty ? nil : calls))
            text = nil
            calls = []
        }
        for item in items {
            switch item {
            case .user(let value):
                flush()
                result.append(.user(value))
            case .assistant(let value):
                flush()
                text = value
            case .toolCall(let id, let name, let arguments):
                calls.append(MLXBridge.toolCall(id: id, name: name, arguments: arguments))
            case .toolOutput(let callID, let output):
                flush()
                result.append(.tool(output, id: callID))
            case .opaque:
                continue
            }
        }
        flush()
        return result
    }
}
