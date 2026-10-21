import Foundation

/// The models the picker offers by name, and how a model id reads in a label.
enum IDEAIModelNames {
    /// Claude models offered in the picker. A custom id set in Manage Models is listed after these.
    static let claude: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-haiku-5-5", "Haiku 5.5"),
        ("claude-fable-5-1", "Fable 5.1"),
    ]

    /// "Opus 5.5" for a known Claude id, the id itself otherwise.
    static func display(provider: IDEAgentProvider, model: String) -> String {
        if provider == .anthropic, let known = claude.first(where: { $0.id == model }) { return known.name }
        return model.isEmpty ? provider.title : model
    }

    /// What follows the model in a label: "High", or nothing when reasoning is off.
    static func effortLabel(_ effort: String) -> String? {
        effort == "off" || effort.isEmpty ? nil : effort.capitalized
    }
}
