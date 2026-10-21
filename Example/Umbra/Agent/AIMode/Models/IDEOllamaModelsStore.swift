import AgentKit
import Foundation
import Observation

/// Pulling and deleting Ollama models from AI mode, over the same endpoint the agent uses. One pull at a
/// time, with progress; the settings' list of installed models is reloaded after each change.
@MainActor
@Observable
final class IDEOllamaModelsStore {
    static let shared = IDEOllamaModelsStore(settings: .shared)

    private(set) var pullingName: String?
    private(set) var progress: OllamaPullProgress?
    private(set) var error: String?
    private(set) var deletingName: String?

    @ObservationIgnored private let settings: IDEAgentSettings
    @ObservationIgnored private let transport: any LLMTransport
    @ObservationIgnored private var pullTask: Task<Void, Never>?

    init(settings: IDEAgentSettings, transport: any LLMTransport = URLSessionTransport()) {
        self.settings = settings
        self.transport = transport
    }

    var isPulling: Bool { pullingName != nil }

    private func catalog() -> OllamaModelCatalog? {
        settings.endpointURL(for: .ollama).map { OllamaModelCatalog(baseURL: $0, transport: transport) }
    }

    /// Downloads `name` (for example `qwen3:8b`). Cancelling keeps the layers fetched, so a second pull resumes.
    func pull(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPulling, !name.isEmpty else { return }
        guard let catalog = catalog() else {
            error = "Set a valid Ollama address first."
            return
        }
        pullingName = name
        progress = nil
        error = nil
        pullTask = Task { [weak self] in
            do {
                for try await update in catalog.pull(name) { self?.progress = update }
                self?.finishPull(error: nil)
            } catch is CancellationError {
                self?.finishPull(error: nil)
            } catch {
                self?.finishPull(error: error.localizedDescription)
            }
        }
    }

    func cancelPull() { pullTask?.cancel() }

    private func finishPull(error: String?) {
        pullingName = nil
        progress = nil
        pullTask = nil
        self.error = error
        Task { await settings.refreshOllamaModels(adjustSelection: false) }
    }

    func delete(_ name: String) async {
        guard let catalog = catalog(), deletingName == nil else { return }
        deletingName = name
        error = nil
        do {
            try await catalog.delete(name)
        } catch {
            self.error = error.localizedDescription
        }
        deletingName = nil
        await settings.refreshOllamaModels(adjustSelection: false)
    }
}
