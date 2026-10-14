import EditorIntelligence
import Foundation

/// Hovering a `###@scheme:` line says whether its schema is loaded, loading, or why it is not.
final class HTTPSchemaHoverProvider: HoverProvider, @unchecked Sendable {
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
        let contents: String
        switch await store.state(for: request.url) {
        case .loaded(let types, let date)?:
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            contents = "**GraphQL schema** · \(types) types · loaded \(formatter.localizedString(for: date, relativeTo: Date()))\n\n\(address)"
        case .loading?:
            contents = "**GraphQL schema** · loading…\n\n\(address)"
        case .failed(let message, _)?:
            contents = "**GraphQL schema** · could not be loaded\n\n\(message)\n\n\(address)\n\nRun **HTTP: Refresh GraphQL Schema** to try again."
        case nil:
            contents = "**GraphQL schema** · not loaded\n\n\(address)\n\nRun **HTTP: Refresh GraphQL Schema** to fetch it. Addresses other than `https` and this Mac are only read on request."
        }
        return HoverResult(contents: contents, source: name)
    }
}
