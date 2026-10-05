import AgentEvalKit
import AgentKit
import AgentKitMLX
import Foundation
import LocalModelStore

struct ProviderSetup {
    var client: any LLMClient
    var label: String
    /// The window sessions compact against. Local models use what they were asked for.
    var contextWindow: Int?
    var isLocal: Bool
    /// Ollama leaves more room: a prompt past `num_ctx` may truncate without an error, and the
    /// estimate is then the only guard.
    var compactionThreshold: Double = 0.75
}

enum ProviderError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { text } else { "" } }
}

enum Providers {
    static let defaultLocalContext = 32_768

    static func make(_ options: Options) async throws -> ProviderSetup {
        guard let model = options.model, !model.isEmpty else { throw ProviderError.message("--model is required.") }
        switch options.provider {
        case "ollama": return try await ollama(model: model, options: options)
        case "openai", "chat": return try remote(model: model, options: options)
        case "mlx": return try mlx(model: model, options: options)
        default: throw ProviderError.message("Unknown provider “\(options.provider)”. Use ollama, openai, chat or mlx.")
        }
    }

    private static func endpointURL(_ options: Options, fallback: String) throws -> URL {
        let text = options.baseURL ?? fallback
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else {
            throw ProviderError.message("“\(text)” is not an http(s) URL.")
        }
        return url
    }

    private static func ollama(model: String, options: Options) async throws -> ProviderSetup {
        let url = try endpointURL(options, fallback: OllamaClient.defaultBaseURL.absoluteString)
        let models: [OllamaModel]
        do { models = try await OllamaModelCatalog(baseURL: url).models() } catch {
            throw ProviderError.message("Could not reach Ollama at \(url.absoluteString): \(error.localizedDescription)")
        }
        guard let info = models.first(where: { $0.name == model }) else {
            let names = models.map(\.name).prefix(8).joined(separator: ", ")
            throw ProviderError.message("Ollama has no model “\(model)”. Installed: \(names.isEmpty ? "none" : names)")
        }
        if !info.capabilities.isEmpty, !info.supportsTools {
            throw ProviderError.message("“\(model)” does not support tool calling, which the agent needs.")
        }
        let context = min(options.contextWindow ?? defaultLocalContext, info.contextLength ?? .max)
        let client = OllamaClient(endpoint: LLMEndpoint(baseURL: url, apiKey: nil), contextLength: context, supportsThinking: info.supportsThinking)
        return ProviderSetup(
            client: client, label: "ollama · \(model) · \(context / 1024)K context", contextWindow: context, isLocal: true,
            compactionThreshold: 0.60)
    }

    private static func remote(model: String, options: Options) throws -> ProviderSetup {
        let url = try endpointURL(options, fallback: "https://api.openai.com/v1")
        let variable = options.apiKeyEnvironment ?? "OPENAI_API_KEY"
        let key = ProcessInfo.processInfo.environment[variable].flatMap { $0.isEmpty ? nil : $0 }
        let isLocalHost = ["localhost", "127.0.0.1", "::1"].contains(url.host()?.lowercased() ?? "")
        if key == nil, !isLocalHost { throw ProviderError.message("Set \(variable) to an API key for \(url.host() ?? "the server").") }
        let endpoint = LLMEndpoint(baseURL: url, apiKey: key)
        if options.provider == "openai" {
            return ProviderSetup(client: OpenAIResponsesClient(endpoint: endpoint), label: "openai · \(model)", contextWindow: options.contextWindow, isLocal: isLocalHost)
        }
        let capabilities: ChatCompletionsCapabilities = url.host() == "api.openai.com" ? .openAI : .compatible
        return ProviderSetup(
            client: OpenAIChatCompletionsClient(endpoint: endpoint, capabilities: capabilities),
            label: "chat · \(model) · \(url.host() ?? "")", contextWindow: options.contextWindow, isLocal: isLocalHost)
    }

    private static func mlx(model: String, options: Options) throws -> ProviderSetup {
        let status = MLXAvailability.currentStatus()
        guard status == .available else { throw ProviderError.message(MLXAvailability.message(for: status)) }
        let root: URL
        if let folder = options.modelsDirectory {
            root = folder
        } else {
            do { root = try LocalModelPaths.defaultRoot(folderName: "com.umbra.editor") } catch {
                throw ProviderError.message("The models folder could not be found: \(error.localizedDescription)")
            }
        }
        let installed = LocalModelCatalog(paths: LocalModelPaths(root: root)).installed()
        guard let found = installed.first(where: { $0.id == model }) else {
            let names = installed.map(\.id).joined(separator: ", ")
            throw ProviderError.message("“\(model)” is not installed. Installed: \(names.isEmpty ? "none (download one in Umbra)" : names)")
        }
        let info = MLXModelInspector.inspect(directory: found.directory)
        if info.hasChatTemplate, !info.supportsTools { throw ProviderError.message("“\(model)” has a chat template without tool support.") }
        let context = min(options.contextWindow ?? defaultLocalContext, info.contextLength ?? .max)
        return ProviderSetup(
            client: MLXLLMClient(model: found, settings: MLXGenerationSettings()),
            label: "mlx · \(model) · \(context / 1024)K context", contextWindow: context, isLocal: true)
    }
}
