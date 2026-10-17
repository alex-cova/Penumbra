import AgentKitMLX
import EditorIntelligence
import Foundation
import LocalModelStore

/// Full-line completion backed by a local MLX model. Owns a dedicated
/// ``LocalModelRuntime`` (not `.shared`, which holds one model and would evict the
/// agent's), loads the chosen model lazily on the first request after it is enabled,
/// and unloads it after 10 idle minutes. Inference is local; nothing is downloaded or
/// loaded until the user enables the feature and picks or downloads a model.
final class IDEInlineCompletionService: InlineCompletionModel, @unchecked Sendable {
    static let shared = IDEInlineCompletionService()
    /// The one-click download in Settings: a 1.5B coder model trained for FIM, ≈0.9 GB.
    static let recommendedModelID = "mlx-community/Qwen2.5-Coder-1.5B-4bit"

    let runtime = LocalModelRuntime()

    init() {
        Task { [runtime] in await runtime.setIdleTimeout(.seconds(10 * 60)) }
    }

    /// The installed model the user picked for code completion, if it is still installed.
    /// Read from the same defaults key `IDEPreferences` writes (it is main-actor isolated).
    private var chosenModel: InstalledLocalModel? {
        guard let id = UserDefaults.standard.string(forKey: "com.umbra.editor.inlineCompletionModel") else { return nil }
        return Self.installedModels().first { $0.id == id }
    }

    static func installedModels() -> [InstalledLocalModel] {
        guard let root = try? LocalModelPaths.defaultRoot(folderName: "com.umbra.editor") else { return [] }
        return LocalModelCatalog(paths: LocalModelPaths(root: root)).installed()
    }

    func complete(_ request: InlineCompletionRequest) -> AsyncThrowingStream<String, Error> {
        guard let model = chosenModel else {
            return AsyncThrowingStream { $0.finish() }
        }
        let info = MLXModelInspector.inspect(directory: model.directory)
        let prompt: String
        if info.fimFormat != nil {
            let path = request.filePath ?? "Untitled"
            prompt = "<|file_sep|>\(path)\n<|fim_prefix|>\(request.prefix)<|fim_suffix|>\(request.suffix)<|fim_middle|>"
        } else {
            // No FIM format: prefix only, the model continues the line.
            prompt = request.prefix
        }
        let client = MLXTextCompletionClient(runtime: runtime, model: model)
        return client.complete(TextCompletionRequest(
            prompt: prompt, maxTokens: request.maxTokens, stop: request.stop, temperature: 0
        ))
    }

    struct Status: Equatable, Sendable {
        var text: String
        var isError = false
    }

    /// "Loaded Qwen2.5-Coder-1.5B-4bit · 912 MB" or "Not loaded", for the settings pane.
    func statusText() async -> String {
        guard let loaded = await runtime.loaded else { return "Not loaded" }
        let bytes = await runtime.memoryBytes()
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        return "Loaded \(LocalModelFormat.shortName(loaded.model.id)) · \(size)"
    }

    /// Loads the model chosen in Settings into this service's runtime, ahead of the first suggestion.
    func loadChosenModel() async -> Status {
        guard let model = chosenModel else {
            return Status(text: "Choose an installed model first.", isError: true)
        }
        do {
            _ = try await runtime.load(model)
            return Status(text: await statusText())
        } catch {
            return Status(text: error.localizedDescription, isError: true)
        }
    }

    func unload() {
        Task { [runtime] in await runtime.unload() }
    }
}
