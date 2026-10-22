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
    /// Bits per weight from the model's `quantization` config, if it is quantized.
    public let quantizationBits: Int?
    /// Fill-in-the-middle format the tokenizer's vocabulary supports, if any.
    public let fimFormat: FIMFormat?

    public init(
        modelType: String?, contextLength: Int?, hasChatTemplate: Bool, supportsTools: Bool,
        quantizationBits: Int? = nil, fimFormat: FIMFormat? = nil
    ) {
        self.modelType = modelType
        self.contextLength = contextLength
        self.hasChatTemplate = hasChatTemplate
        self.supportsTools = supportsTools
        self.quantizationBits = quantizationBits
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
            quantizationBits: quantizationBits(in: config),
            fimFormat: fimFormat(modelType: modelType, tokens: tokenizerTokens(in: directory)))
    }

    /// Whether the repository name says this is a base model, which continues text instead of chatting:
    /// it never ends a turn and writes the next `User:` line itself. Only the files of a base model
    /// and its Instruct sibling are identical (same `config.json`, tokenizer and chat template), so the
    /// name is the one signal. It is recognised by a `Base` or `pt` (pretrained) part, or by the
    /// Qwen2.5 families, whose base repos carry no tag (`Qwen2.5-Coder-1.5B-4bit`) while the chat ones
    /// say `Instruct`. Other untagged families are not guessed at: `DeepSeek-R1-Distill-Qwen-7B`
    /// chats fine, and a model wrongly refused is worse than one that gets the loop guards.
    public static func isBaseModelName(_ id: String) -> Bool {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        let parts = name.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        if parts.contains("base") || parts.contains("pt") { return true }
        return name.range(of: #"^Qwen2\.5(-Coder|-Math)?-\d+(\.\d+)?B(-\d+-?bit|-bf16|-fp16)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A message for the UI when the model is for completion only, else `nil`.
    public static func baseModelMessage(modelID: String) -> String? {
        guard isBaseModelName(modelID) else { return nil }
        return "“\(modelID)” is a base model, not tuned to chat: it continues text and does not stop. Use it for Code Completion, or choose an Instruct model for chat."
    }

    /// What MLX's quantize accepts. Anything else crashes the loader, so it is refused first.
    public static let supportedQuantizationBits: Set<Int> = [2, 3, 4, 5, 6, 8]

    /// Bits per weight from `config.json`'s `quantization`, which multimodal and some newer
    /// configs nest under `text_config`. `nil` when the weights are not quantized that way.
    public static func quantizationBits(in directory: URL) -> Int? {
        let config = (try? Data(contentsOf: directory.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return quantizationBits(in: config)
    }

    /// A message for the UI when the weights' quantization cannot be loaded, else `nil`.
    public static func unsupportedQuantizationMessage(modelID: String, bits: Int?) -> String? {
        guard let bits, !supportedQuantizationBits.contains(bits) else { return nil }
        return "“\(modelID)” is quantized to \(bits) bit, which MLX cannot run (2, 3, 4, 5, 6 or 8 bits). Choose a 4-bit model."
    }

    static func quantizationBits(in config: [String: Any]?) -> Int? {
        let top = (config?["quantization"] as? [String: Any])?["bits"] as? Int
        let nested = ((config?["text_config"] as? [String: Any])?["quantization"] as? [String: Any])?["bits"] as? Int
        return top ?? nested
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
