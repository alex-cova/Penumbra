import Foundation
import LocalModelStore

/// What an installed model's own files say about it.
public struct MLXModelInfo: Sendable, Equatable {
    public let modelType: String?
    /// `max_position_embeddings`: the longest context the weights were trained for.
    public let contextLength: Int?
    public let hasChatTemplate: Bool
    /// The chat template takes `tools`, so the model can be asked to call functions.
    public let supportsTools: Bool

    public init(modelType: String?, contextLength: Int?, hasChatTemplate: Bool, supportsTools: Bool) {
        self.modelType = modelType
        self.contextLength = contextLength
        self.hasChatTemplate = hasChatTemplate
        self.supportsTools = supportsTools
    }
}

public enum MLXModelInspector {
    public static func inspect(directory: URL) -> MLXModelInfo {
        let config = (try? Data(contentsOf: directory.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // Multimodal and some newer configs nest the language model under `text_config`.
        let text = config?["text_config"] as? [String: Any]
        let context = (config?["max_position_embeddings"] as? Int) ?? (text?["max_position_embeddings"] as? Int)

        let template = ChatTemplate.extract(
            tokenizerConfig: try? Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json")),
            jinja: try? String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8),
            templateJSON: try? Data(contentsOf: directory.appendingPathComponent("chat_template.json")))
        return MLXModelInfo(
            modelType: (config?["model_type"] as? String) ?? (text?["model_type"] as? String),
            contextLength: context,
            hasChatTemplate: template != nil,
            supportsTools: template.map(ChatTemplate.supportsTools) ?? false)
    }
}
