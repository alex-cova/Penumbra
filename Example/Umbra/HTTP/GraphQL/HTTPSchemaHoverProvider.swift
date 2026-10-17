import EditorIntelligence
import Foundation

/// Hovering a `###@scheme:` line shows its schema (when loaded) with a button that opens
/// the full schema in the editor to the right.
final class HTTPSchemaHoverProvider: HoverProvider, @unchecked Sendable {
    /// Action id the workspace agrees to handle: `arguments` carries the schema URL.
    static let openActionID = "umbra.openGraphQLSchema"

    typealias GlobalsSource = @Sendable () -> [String: String]

    let name = "HTTP schema"

    private let lock = NSLock()
    private var store: GraphQLSchemaStore?
    private var globalsSource: GlobalsSource = { [:] }

    func configure(store: GraphQLSchemaStore?, globals: @escaping GlobalsSource) {
        lock.lock()
        self.store = store
        globalsSource = globals
        lock.unlock()
    }

    private func snapshot() -> (GraphQLSchemaStore?, [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        return (store, globalsSource())
    }

    func provide(context: HoverContext) async -> HoverResult? {
        guard context.document.languageIdentifier == "http" else { return nil }
        let (store, globals) = snapshot()
        let text = context.document.httpText
        let caret = context.cursor.position.utf16Offset
        guard let store,
              let directive = HTTPGraphQLDirective.directive(in: text, caretUTF16: caret),
              directive.lineRange.lowerBound <= caret, caret <= directive.lineRange.upperBound else {
            return nil
        }
        let request: GraphQLSchemaRequest
        switch GraphQLSchemaResolver.resolve(directive, in: text, fileURL: context.document.url, globals: globals) {
        case .failure(let error):
            return HoverResult(contents: "**GraphQL schema**\n\n\(error.localizedDescription)", source: name)
        case .success(let resolved):
            request = resolved
        }
        await store.prefetch(request)
        let address = "`\(request.url.isFileURL ? request.url.path : request.url.absoluteString)`"
        let open = HoverAction(
            id: Self.openActionID,
            title: "Open schema in right split",
            arguments: [request.url.absoluteString]
        )
        let contents: String
        switch await store.state(for: request.url) {
        case .loaded(let types, let date)?:
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            contents = """
                **GraphQL schema** · \(types) types · loaded \
                \(formatter.localizedString(for: date, relativeTo: Date()))

                \(address)\(await schemaExcerpt(request, store: store))
                """
        case .loading?:
            contents = "**GraphQL schema** · loading…\n\n\(address)"
        case .failed(let message, _)?:
            contents = "**GraphQL schema** · could not be loaded\n\n\(message)\n\n\(address)\n\nRun **HTTP: Refresh GraphQL Schema** to try again."
        case nil:
            contents = "**GraphQL schema** · not loaded\n\n\(address)\n\nRun **HTTP: Refresh GraphQL Schema** to fetch it. Addresses other than `https` and this Mac are only read on request."
        }
        return HoverResult(contents: contents, source: name, actions: [open])
    }

    /// The loaded schema as a fenced excerpt, or nothing when it is not loaded yet. Fenced so
    /// SDL punctuation (`#`, `*`, `|`) is never read as Markdown.
    private func schemaExcerpt(_ request: GraphQLSchemaRequest, store: GraphQLSchemaStore) async -> String {
        guard let schema = await store.schema(for: request) else { return "" }
        let excerpt = GraphQLSchemaText.excerpt(for: schema)
        guard !excerpt.isEmpty else { return "" }
        return "\n\n```graphql\n\(excerpt)\n```"
    }
}
