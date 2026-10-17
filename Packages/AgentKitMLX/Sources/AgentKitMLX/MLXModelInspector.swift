import Foundation
import LocalModelStore

/// How a model spells fill-in-the-middle, when it was trained for it.
public enum FIMFormat: Sendable, Equatable {
    /// Qwen2.5-Coder: `<|fim_prefix|>…<|fim_suffix|>…<|fim_middle|>`.
    case qwenCoder

    public var prefixToken: String { "<|fim_prefix|>" }
    public var suffixToken: String { "<|fim_suffix|>" }
    public var middleToken: String { "<|fim_middle|>" }
}

/// What an installed model's own files say about it.
public struct MLXModelInfo: Sendable, Equatable {
    public let modelType: String?
    /// `max_position_embeddings`: the longest context the weights were trained for.
    public let contextLength: Int?
    public let hasChatTemplate: Bool
    /// The chat template takes `tools`, so the model can be asked to call functions.
    public let supportsTools: Bool
    /// Fill-in-the-middle format the tokenizer's vocabulary supports, if any.
    public let fimFormat: FIMFormat?

    public init(
        modelType: String?, contextLength: Int?, hasChatTemplate: Bool, supportsTools: Bool,
        fimFormat: FIMFormat? = nil
    ) {
        self.modelType = modelType
        self.contextLength = contextLength
        self.hasChatTemplate = hasChatTemplate
        self.supportsTools = supportsTools
        self.fimFormat = fimFormat
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
        let modelType = (config?["model_type"] as? String) ?? (text?["model_type"] as? String)
        return MLXModelInfo(
            modelType: modelType,
            contextLength: context,
            hasChatTemplate: template != nil,
            supportsTools: template.map(ChatTemplate.supportsTools) ?? false,
            fimFormat: fimFormat(modelType: modelType, tokens: tokenizerTokens(in: directory)))
    }

    /// Qwen2.5-Coder FIM when the vocabulary has all three FIM tokens and the model is a
    /// `qwen2`. Anything else gets no FIM format, and prompting falls back to prefix only.
    static func fimFormat(modelType: String?, tokens: Set<String>) -> FIMFormat? {
        guard modelType == "qwen2" else { return nil }
        let needed: Set<String> = ["<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>"]
        return needed.isSubset(of: tokens) ? .qwenCoder : nil
    }

    /// Special tokens named by `tokenizer_config.json` (its added tokens and the named
    /// special-token fields), plus any `<|fim_…|>` keys of `tokenizer.json`'s added tokens.
    static func tokenizerTokens(in directory: URL) -> Set<String> {
        var tokens = Set<String>()
        if let data = try? Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let added = config["added_tokens_decoder"] as? [String: Any] {
                for entry in added.values {
                    if let content = (entry as? [String: Any])?["content"] as? String { tokens.insert(content) }
                }
            }
            for key in ["bos_token", "eos_token", "pad_token", "unk_token"] {
                if let value = config[key] as? String { tokens.insert(value) }
                if let value = (config[key] as? [String: Any])?["content"] as? String { tokens.insert(value) }
            }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("tokenizer.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let added = json["added_tokens"] as? [[String: Any]] {
            for entry in added {
                if let content = entry["content"] as? String { tokens.insert(content) }
            }
        }
        return tokens
    }
}
