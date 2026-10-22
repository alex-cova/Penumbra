import Foundation
import Testing
@testable import AgentKitMLX

/// A base model behind a chat template continues the text and never stops, so Umbra keeps it out of
/// chat. Its files are the Instruct sibling's (checked for Qwen2.5-Coder-1.5B: `config.json`, tokenizer
/// and chat template are identical, `eos_token_id` is 151643 in both), so only the name tells them apart.
@Suite struct MLXBaseModelDetectionTests {
    @Test func theTagsBaseAndPtMarkABaseModel() {
        for id in ["Qwen/Qwen3-4B-Base", "mlx-community/Qwen3-4B-Base-4bit", "mlx-community/gemma-3-4b-pt-4bit"] {
            #expect(MLXModelInspector.isBaseModelName(id), "\(id)")
        }
    }

    @Test func untaggedQwen25ReposAreBaseModels() {
        for id in [
            "mlx-community/Qwen2.5-Coder-1.5B-4bit", "mlx-community/Qwen2.5-7B-4bit", "mlx-community/Qwen2.5-3B-8bit",
            "mlx-community/Qwen2.5-Coder-7B-bf16", "Qwen/Qwen2.5-0.5B",
        ] {
            #expect(MLXModelInspector.isBaseModelName(id), "\(id)")
        }
    }

    @Test func chatModelsAreNotMistakenForBaseModels() {
        for id in [
            "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit", "mlx-community/Qwen2.5-3B-Instruct-4bit",
            "mlx-community/Qwen3-4B-4bit", "mlx-community/Qwen3-1.7B-4bit", "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "mlx-community/gemma-3-4b-it-4bit", "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
            "mlx-community/Hermes-3-Llama-3.1-8B-4bit", "acme/Database-7B", "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
        ] {
            #expect(!MLXModelInspector.isBaseModelName(id), "\(id)")
        }
    }

    @Test func theMessageNamesTheModelAndTheWayOut() {
        let message = MLXModelInspector.baseModelMessage(modelID: "mlx-community/Qwen2.5-Coder-1.5B-4bit")
        #expect(message?.contains("Qwen2.5-Coder-1.5B-4bit") == true && message?.contains("Instruct") == true)
        #expect(MLXModelInspector.baseModelMessage(modelID: "mlx-community/Qwen3-4B-4bit") == nil)
    }
}
