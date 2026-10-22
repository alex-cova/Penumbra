import Foundation

/// What tool definitions cost in a request: the part of every request that comes before the conversation.
/// An estimate from characters, with a factor per provider measured against the providers' own input-token
/// counts (2026-10-22, tool definitions and system prompt of this package): Claude 2.4–2.65 characters
/// per token, OpenAI `gpt-4.1-mini` 5.1–5.4, Ollama `bonsai-2` 3.2–3.7. Good to about 15%; the provider's
/// reported usage is the truth, this is for deciding what to show and what to send.
public enum ToolCost {
    /// Characters per token for a provider, by its `LLMClient.providerID` or the host's name for it.
    public static func charactersPerToken(provider: String) -> Double {
        let id = provider.lowercased()
        if id.contains("anthropic") || id.contains("claude") { return 2.5 }
        if id.contains("openai") || id == "responses" || id == "chat" { return 5.2 }
        if id.contains("ollama") { return 3.4 }
        return 3.0
    }

    /// Characters a tool puts in a request: its name, description and (non-strict) schema.
    public static func characters(of definition: ToolDefinition) -> Int {
        definition.name.count + definition.description.count + ((try? definition.schema(strict: false).serialized().count) ?? 0)
    }

    public static func tokens(of definition: ToolDefinition, provider: String) -> Int {
        tokens(characters: characters(of: definition), provider: provider)
    }

    public static func tokens(of definitions: [ToolDefinition], provider: String) -> Int {
        tokens(characters: definitions.reduce(0) { $0 + characters(of: $1) }, provider: provider)
    }

    public static func tokens(ofText text: String, provider: String) -> Int {
        tokens(characters: text.count, provider: provider)
    }

    static func tokens(characters: Int, provider: String) -> Int {
        Int((Double(characters) / charactersPerToken(provider: provider)).rounded(.up))
    }
}
