import Foundation
import Observation

/// AI mode's own preferences, kept on this Mac: the model last picked for Chat and for Code (new
/// chats start with it), and the instruction Chat gives the model. Endpoints, keys and consent stay in
/// `IDEAgentSettings`, which both halves share.
@MainActor
@Observable
final class IDEAISettings {
    static let shared = IDEAISettings()

    static let defaultChatSystemPrompt = """
    You are a helpful assistant in Umbra, a macOS editor. Answer directly and concisely. \
    Use Markdown when it helps: short lists, and fenced code blocks with a language for any code. \
    If you are not sure of something, say so instead of guessing.
    """

    /// The model new Chat conversations start with; `nil` until the user picks one.
    var chatChoice: IDEAIModelChoice? { didSet { save(chatChoice, forKey: Keys.chatChoice) } }
    /// The model new Code sessions start with; `nil` follows Settings ▸ Agent.
    var codeChoice: IDEAIModelChoice? { didSet { save(codeChoice, forKey: Keys.codeChoice) } }
    var chatSystemPrompt: String { didSet { defaults.set(chatSystemPrompt, forKey: Keys.chatPrompt) } }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let chatChoice = "umbra.ai.chatChoice"
        static let codeChoice = "umbra.ai.codeChoice"
        static let chatPrompt = "umbra.ai.chatSystemPrompt"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chatChoice = Self.load(from: defaults, key: Keys.chatChoice)
        codeChoice = Self.load(from: defaults, key: Keys.codeChoice)
        chatSystemPrompt = defaults.string(forKey: Keys.chatPrompt) ?? Self.defaultChatSystemPrompt
    }

    private func save(_ choice: IDEAIModelChoice?, forKey key: String) {
        if let choice, let data = try? JSONEncoder().encode(choice) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> IDEAIModelChoice? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(IDEAIModelChoice.self, from: $0) }
    }
}
