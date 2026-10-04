import Foundation
import MLXLMCommon

enum MLXTestSupport {
    /// The tool calls an assistant `Chat.Message` carries, read back through MLX's own message
    /// generator, which is how a chat template sees them.
    static func calls(in tool: Chat.Message.Tool) -> [ToolCall] {
        let message = Chat.Message(role: .assistant, content: "", tool: tool)
        let dictionary = DefaultMessageGenerator().generate(message: message)
        guard let raw = dictionary["tool_calls"] as? [[String: any Sendable]] else { return [] }
        return raw.compactMap { entry in
            guard let function = entry["function"] as? [String: any Sendable], let name = function["name"] as? String else { return nil }
            let arguments = function["arguments"] as? [String: any Sendable] ?? [:]
            return ToolCall(function: .init(name: name, arguments: arguments), id: entry["id"] as? String)
        }
    }
}
