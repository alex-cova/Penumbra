import Foundation

public enum FinishReason: String, Sendable, Hashable, Codable {
    case completed
    case toolCalls
    case length
    case contentFilter
    /// The client ended the turn itself because the model degenerated: it repeated one unit
    /// endlessly or wrote the user's next turn. What was streamed is kept.
    case degenerate
}

public enum LLMEvent: Sendable, Hashable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallStarted(id: String, name: String)
    case toolCallArgumentsDelta(id: String, delta: String)
    case toolCallFinished(id: String, name: String, arguments: String)
    case opaqueItem(OpaqueItem)
    /// The model tried to call a tool but what it wrote could not be read (broken JSON in a
    /// local model's tool-call syntax). The loop tells the model and lets it try again; `raw` is the
    /// start of what it wrote.
    case unreadableToolCall(detail: String, raw: String)
    case usage(TokenUsage)
    case finished(FinishReason)
    /// The turn failed in a way worth retrying and is being resent: the consumer drops what it
    /// received from this turn so far. Safe because tools only run after a turn ends.
    case retrying(attempt: Int, after: TimeInterval)
}

/// What the model may do with the tools it is shown.
public enum ToolChoice: Sendable, Hashable {
    /// The model must answer in text. The tools stay in the request so the provider's cached prefix
    /// (which starts with the tool list) survives the closing turn of a run.
    case disabled
}

public struct LLMRequest: Sendable {
    public var model: String
    public var system: String
    public var items: [ConversationItem]
    public var tools: [ToolDefinition]
    /// `nil` leaves the choice to the model. Sent only when the client `supportsDisabledToolChoice`.
    public var toolChoice: ToolChoice?
    /// `nil` for models without reasoning. Otherwise the provider's effort name ("low", "medium", "high").
    public var reasoningEffort: String?
    public var maxOutputTokens: Int?
    /// Stable per session so the provider can route requests to the same cache.
    public var cacheKey: String?
    /// The window the host is compacting against, when it set one. A local client uses it to
    /// refuse a prompt that cannot fit, so the session can compact and retry.
    public var contextWindow: Int?

    public init(
        model: String,
        system: String = "",
        items: [ConversationItem],
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice? = nil,
        reasoningEffort: String? = nil,
        maxOutputTokens: Int? = nil,
        cacheKey: String? = nil,
        contextWindow: Int? = nil
    ) {
        self.model = model
        self.system = system
        self.items = items
        self.tools = tools
        self.toolChoice = toolChoice
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
        self.cacheKey = cacheKey
        self.contextWindow = contextWindow
    }
}

/// One model request and its streamed response. The loop never sees which API sits behind it.
///
/// A stream ends after `.finished`, or throws an `LLMError`. Cancelling the consuming task must
/// close the connection.
public protocol LLMClient: Sendable {
    /// Tags the `OpaqueItem`s this client produces, so they are replayed only to it.
    var providerID: String { get }
    /// Whether the endpoint takes `ToolChoice.disabled` with a tool list. When it does not, the closing
    /// turn of a run is sent with no tools instead.
    var supportsDisabledToolChoice: Bool { get }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

extension LLMClient {
    public var supportsDisabledToolChoice: Bool { false }
}

public enum LLMError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String)
    case contextLengthExceeded
    case badRequest(status: Int, message: String)
    /// An `error` or `response.failed` event inside an otherwise healthy stream.
    case api(message: String, code: String?)
    /// The connection dropped, or the stream ended before the provider said it was done.
    case connectionLost(String)
    /// The connection dropped after the turn had already produced text or a tool call. Resending the
    /// turn would throw that away, so the client does not: the loop keeps what arrived and asks the
    /// model to carry on.
    case interruptedAfterOutput(String)
    /// Nothing is listening there (connection refused, unknown host). Not retried.
    case unreachable(String)
    case malformedEvent(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The API rejected the key. Check the API key."
        case .rateLimited: "The API is rate limiting requests."
        case .server(let status, let message): "The API had a server error (\(status)): \(message)"
        case .contextLengthExceeded: "The conversation no longer fits the model's context window."
        case .badRequest(let status, let message): "The API rejected the request (\(status)): \(message)"
        case .api(let message, _): message
        case .connectionLost(let detail), .interruptedAfterOutput(let detail): "The connection to the API was lost: \(detail)"
        case .unreachable(let detail): detail
        case .malformedEvent(let detail): "The API sent an event that could not be read: \(detail)"
        }
    }
}
