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

    /// Muse models from Meta shipped with the app: the picker's fallback before a key is saved
    /// (and when the live list cannot be fetched). Once `IDEAgentSettings.refreshMetaModels()`
    /// succeeds, the picker offers what `api.meta.ai` lists instead, so a model released after
    /// this build appears without an app update; these ids only keep the menu working offline.
    static let muse: [(id: String, name: String)] = [
        ("muse-spark-1.3", "Muse Spark 1.3"),
        ("muse-spark-1.2", "Muse Spark 1.2"),
        ("muse-spark-1.1", "Muse Spark 1.1"),
        ("muse-wonder-1.0", "Muse Wonder 1.0"),
    ]

    /// Whether an id from Meta's `/models` is something the picker can chat with. The endpoint also
    /// lists an image generator (`muse-image-1.0`), a transcriber (`muse-voice-transcribe-1.0`) and
    /// `sam-3.1`, none of which take a conversation. An exclusion list rather than a list of known
    /// families, so a new Muse chat model still appears without an app update.
    static func isMuseChatModel(_ id: String) -> Bool {
        let name = id.lowercased()
        guard name.hasPrefix("muse-") else { return false }
        return !["image", "voice", "transcribe", "audio", "speech", "embed"].contains { name.contains($0) }
    }

    /// "Opus 5.5" for a known Claude id, the id itself otherwise.
    static func display(provider: IDEAgentProvider, model: String) -> String {
        if provider == .anthropic, let known = claude.first(where: { $0.id == model }) { return known.name }
        if provider == .meta, let known = muse.first(where: { $0.id == model }) { return known.name }
        switch provider {
        case .apple: return "Apple Intelligence"
        case .applePCC: return "Private Cloud Compute"
        default: break
        }
        return model.isEmpty ? provider.title : model
    }

    /// What follows the model in a label: "High", or nothing when reasoning is off.
    static func effortLabel(_ effort: String) -> String? {
        effort == "off" || effort.isEmpty ? nil : effort.capitalized
    }
}
