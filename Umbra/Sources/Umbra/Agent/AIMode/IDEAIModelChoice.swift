import Foundation

/// The model one chat uses in AI mode. A chat with no choice follows the global agent settings
/// (Settings ▸ Agent), which is how the docked panel works; a choice overrides provider, model and
/// reasoning for that chat alone, and is saved with it.
///
/// Endpoint addresses and keys stay per provider in `IDEAgentSettings`, so a choice never holds a
/// secret or a URL.
struct IDEAIModelChoice: Codable, Hashable, Sendable {
    var provider: IDEAgentProvider
    var model: String
    /// One of `IDEAgentProvider.reasoningEfforts`; "off" sends no reasoning field.
    var reasoningEffort: String
    /// An external ACP agent that drives the chat. Provider and model are then not used.
    var acpAgentID: UUID?

    init(provider: IDEAgentProvider, model: String, reasoningEffort: String? = nil, acpAgentID: UUID? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort ?? provider.defaultReasoning
        self.acpAgentID = acpAgentID
    }

    /// A model key as an agent's `model:` names it: `provider:model`, such as
    /// `ollama:qwen3-coder:30b` or `mlx:my-org/my-model`. `nil` for anything else.
    init?(parsing key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let provider = IDEAgentProvider(rawValue: String(trimmed[..<colon]))
        let model = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provider, !model.isEmpty, !model.hasPrefix("-") else { return nil }
        self.init(provider: provider, model: model)
    }

    /// The effort to send, or `nil` for "off".
    var effectiveReasoningEffort: String? { reasoningEffort == "off" ? nil : reasoningEffort }

    var isACP: Bool { acpAgentID != nil }
}
