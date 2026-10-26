import AgentKit

/// The `web_search` tool, present only when the user has turned search on and saved a Brave key.
enum IDEAgentWebSearch {
    @MainActor static func tool(settings: IDEAgentSettings) -> WebSearchTool? {
        guard settings.webSearchEnabled, let key = settings.webSearchAPIKey(), !key.isEmpty else { return nil }
        return WebSearchTool(client: BraveWebSearchClient(apiKey: key))
    }
}
