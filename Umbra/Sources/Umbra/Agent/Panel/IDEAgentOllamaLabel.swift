import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import Foundation
import LocalModelStore

enum IDEAgentOllamaLabel {
    /// "qwen-fixed:latest · 27.3B Q4_K_M · 17 GB", or why it can't be used.
    static func title(_ model: OllamaModel) -> String {
        var parts = [model.name]
        let detail = [model.parameterSize, model.quantization].compactMap { $0 }.joined(separator: " ")
        if !detail.isEmpty { parts.append(detail) }
        if model.sizeBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)) }
        let label = parts.joined(separator: " · ")
        return model.supportsTools ? label : label + " (no tool support)"
    }
}
