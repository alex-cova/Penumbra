import Foundation

/// Completion provider that translates LSP completion items into EIP completion items.
public actor LSPCompletionProvider: CompletionProvider {
    public let name = "LSP"
    private let client: LSPClient

    public init(client: LSPClient) {
        self.client = client
    }

    public func provide(context: CompletionContext) async -> [CompletionItem] {
        do {
            let lspItems = try await client.requestCompletions(
                for: context.document,
                at: context.cursor.position
            )
            let text = context.document.text
            return lspItems.map { completionItem(from: $0, source: name, range: context.range, in: text) }
        } catch {
            return []
        }
    }
}
