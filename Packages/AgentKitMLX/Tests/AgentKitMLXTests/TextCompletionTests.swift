import Foundation
import LocalModelStore
import Testing
@testable import AgentKitMLX

@Suite struct TextCompletionTests {
    @Test func stopFilterCutsAtStopString() {
        var filter = TextCompletionStopFilter(stop: ["\n"])
        #expect(filter.consume("names.get(0)") == "names.get(0)")
        #expect(filter.consume("\nreturn;") == "")
        #expect(filter.stopped)
    }

    @Test func stopFilterCutsAtSpecialMarkerSplitAcrossChunks() {
        var filter = TextCompletionStopFilter(stop: [])
        #expect(filter.consume("foo()<|fim_") == "foo()")
        #expect(filter.consume("suffix|>bar") == "")
        #expect(filter.stopped)
    }

    @Test func stopFilterHoldsBackPartialStop() {
        var filter = TextCompletionStopFilter(stop: ["STOP"])
        #expect(filter.consume("abST") == "ab")
        #expect(filter.consume("X") == "STX")
        #expect(filter.finish() == "")
    }

    @Test func fimDetectionNeedsQwen2AndAllTokens() {
        let tokens: Set<String> = ["<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>", "<|endoftext|>"]
        #expect(MLXModelInspector.fimFormat(modelType: "qwen2", tokens: tokens) == .qwenCoder)
        #expect(MLXModelInspector.fimFormat(modelType: "qwen3", tokens: tokens) == nil)
        #expect(MLXModelInspector.fimFormat(modelType: "qwen2", tokens: ["<|fim_prefix|>"]) == nil)
        #expect(MLXModelInspector.fimFormat(modelType: nil, tokens: tokens) == nil)
    }

    @Test func inspectorReadsFIMFromModelFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"{"model_type": "qwen2", "max_position_embeddings": 32768}"#
            .write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try #"{"added_tokens_decoder": {"151643": {"content": "<|endoftext|>"}, "151659": {"content": "<|fim_prefix|>"}, "151660": {"content": "<|fim_suffix|>"}, "151661": {"content": "<|fim_middle|>"}}}"#
            .write(to: directory.appendingPathComponent("tokenizer_config.json"), atomically: true, encoding: .utf8)
        let info = MLXModelInspector.inspect(directory: directory)
        #expect(info.fimFormat == .qwenCoder)
        #expect(info.modelType == "qwen2")
    }
}

/// Real-model FIM smoke test, opt-in:
///
///     AGENTKIT_MLX_FIM_MODEL=mlx-community/Qwen2.5-Coder-1.5B-4bit swift test --filter FIMSmokeTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AGENTKIT_MLX_FIM_MODEL"] != nil))
struct FIMSmokeTests {
    static let configured: Void = {
        LocalModelRuntime.extraMetalSearchRoots = MLXTestEnvironment.resourceRoots()
    }()

    init() { _ = Self.configured }

    @Test func completesTheMiddleOfALine() async throws {
        let modelID = ProcessInfo.processInfo.environment["AGENTKIT_MLX_FIM_MODEL"]!
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentKitMLXTests/Models", isDirectory: true)
        let paths = LocalModelPaths(root: root)
        try paths.createDirectories()
        let model = try await {
            if let existing = LocalModelCatalog(paths: paths).installed().first(where: { $0.id == modelID }) { return existing }
            return try await LocalModelDownloader().download(id: modelID, into: paths, progress: { _ in })
        }()
        let runtime = LocalModelRuntime()
        let loaded = try await runtime.load(model)
        #expect(loaded.info.fimFormat == .qwenCoder)
        let client = MLXTextCompletionClient(runtime: runtime, model: model)
        let prompt = "<|file_sep|>Test.java\n<|fim_prefix|>class Test { String name() { return <|fim_suffix|>; } }<|fim_middle|>"
        var text = ""
        for try await delta in client.complete(TextCompletionRequest(prompt: prompt, maxTokens: 24, stop: ["\n", ";"])) {
            text += delta
        }
        #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "expected a completion, got nothing")
        await runtime.unload()
    }
}
