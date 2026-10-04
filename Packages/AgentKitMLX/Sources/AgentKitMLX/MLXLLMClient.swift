import AgentKit
import Foundation
import LocalModelStore
import MLXLMCommon

public struct MLXGenerationSettings: Sendable, Hashable {
    public var temperature: Float
    public var topP: Float
    /// Local models can loop; an unbounded answer would run until memory does.
    public var maxTokens: Int

    public init(temperature: Float = 0.2, topP: Float = 0.95, maxTokens: Int = 8_192) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }
}

/// Runs an installed MLX model in this process as an `LLMClient`.
///
/// Prefix caching is the KV cache. The loop hands every client the full history each turn; this
/// client keeps the `ChatSession` of the last turn, and when the new history is exactly what that
/// session has seen plus new items, sends only the new items, so the cache carries over and the
/// transcript is not prefilled again. Anything else (compaction, a model or tool change, a failed
/// or stopped turn) starts a new session from the history, with one full prefill.
public final class MLXLLMClient: LLMClient, @unchecked Sendable {
    public static let providerID = "mlx"
    public var providerID: String { Self.providerID }

    private struct Key: Equatable {
        var modelID: String
        var instructions: String
        var tools: [ToolDefinition]
        var thinking: Bool
        var settings: MLXGenerationSettings
    }

    private struct Live {
        var key: Key
        var session: ChatSession
        /// Everything the session's cache covers: the request's items plus what the model produced.
        var consumed: [ConversationItem]
    }

    private let runtime: LocalModelRuntime
    private let model: InstalledLocalModel
    private let settings: MLXGenerationSettings
    private let lock = NSLock()
    private var live: Live?
    private var lastReuse: Reuse = .none

    /// How the last request used the cache, for tests and diagnostics.
    public enum Reuse: Equatable, Sendable {
        case none
        case rebuilt
        case reused(newItems: Int)
    }

    public init(runtime: LocalModelRuntime = .shared, model: InstalledLocalModel, settings: MLXGenerationSettings = MLXGenerationSettings()) {
        self.runtime = runtime
        self.model = model
        self.settings = settings
    }

    public var lastCacheUse: Reuse { lock.withLock { lastReuse } }

    /// Frees the KV cache (the weights stay loaded).
    public func resetSession() { lock.withLock { live = nil } }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, continuation)
                    continuation.finish()
                } catch is CancellationError {
                    self.resetSession()
                    continuation.finish(throwing: CancellationError())
                } catch {
                    // The cache may be half-updated; never reuse it.
                    self.resetSession()
                    continuation.finish(throwing: (error as? LLMError) ?? LLMError.api(message: error.localizedDescription, code: nil))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - One turn

    private func run(_ request: LLMRequest, _ out: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        let loaded = try await runtime.acquire(model)
        do {
            try await generate(request, loaded: loaded, out)
            await runtime.release()
        } catch {
            await runtime.release()
            throw error
        }
    }

    private func generate(
        _ request: LLMRequest, loaded: LocalModelRuntime.Loaded, _ out: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        guard let split = MLXConversation.split(request.items) else {
            throw LLMError.badRequest(status: 0, message: "The conversation must end with a user message or tool results.")
        }
        let thinking = request.reasoningEffort != nil
        let key = Key(
            modelID: model.id, instructions: request.system, tools: request.tools, thinking: thinking,
            settings: settings)

        let (session, pending, reuse) = prepareSession(key: key, request: request, split: split, loaded: loaded)
        lock.withLock { lastReuse = reuse }

        var parser = LocalModelReasoningParser(allowsImplicitOpen: false)
        var answer = ""
        var calls: [(id: String, name: String, arguments: String)] = []
        var info: GenerateCompletionInfo?
        // A call read by `MLXToolCallRecovery` was never seen by the session, whose own transcript
        // (what it re-renders and matches its cache against) therefore diverges from ours.
        var recoveredACall = false

        func forward(_ deltas: [LocalModelReasoningParser.Delta]) {
            for delta in deltas {
                switch delta {
                case .answer(let text):
                    answer += text
                    out.yield(.textDelta(text))
                case .reasoning(let text):
                    out.yield(.reasoningDelta(text))
                case .reclassifyAnswerAsReasoning, .reasoningEnded:
                    break
                }
            }
        }

        for try await event in session.streamDetails(to: MLXConversation.messages(pending)) {
            try Task.checkCancellation()
            switch event {
            case .chunk(let text):
                forward(parser.consume(text))
            case .toolCall(let call):
                let id = call.id ?? Self.newCallID()
                let arguments = MLXBridge.argumentsText(call)
                calls.append((id, call.function.name, arguments))
                out.yield(.toolCallStarted(id: id, name: call.function.name))
                out.yield(.toolCallFinished(id: id, name: call.function.name, arguments: arguments))
            case .info(let completion):
                info = completion
            case .rejectedToolCall(let rejected):
                if rejected.reason == .malformedSyntax, !rejected.isPreviewTruncated,
                   let recovered = MLXToolCallRecovery.recover(rejected.rawTextPreview, knownTools: Set(request.tools.map(\.name))) {
                    let id = Self.newCallID()
                    recoveredACall = true
                    calls.append((id, recovered.name, recovered.arguments))
                    out.yield(.toolCallStarted(id: id, name: recovered.name))
                    out.yield(.toolCallFinished(id: id, name: recovered.name, arguments: recovered.arguments))
                    continue
                }
                // The loop tells the model and lets it try again; the session's own transcript no longer
                // matches ours (it holds the broken call), so the next request rebuilds from our history.
                recoveredACall = true
                let detail = rejected.detail.map { ": \($0)" } ?? ""
                out.yield(.unreadableToolCall(detail: "\(rejected.reason.rawValue)\(detail)", raw: rejected.rawTextPreview))
            }
        }
        forward(parser.finish())
        try Task.checkCancellation()

        // The cache now covers the request and what the model produced. The loop records exactly this
        // (the answer text, then the calls), which is what lets the next request match it.
        var produced: [ConversationItem] = []
        if !answer.isEmpty { produced.append(.assistant(answer)) }
        produced += calls.map { .toolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
        // After a recovered call the session cannot be trusted to match our history: the next request
        // rebuilds from it (one full prefill) rather than continuing a divergent transcript.
        lock.withLock { live = recoveredACall ? nil : Live(key: key, session: session, consumed: request.items + produced) }

        if let info {
            out.yield(.usage(TokenUsage(
                // The whole prompt, cached part included, is the context in use.
                inputTokens: info.promptTokenCount + info.cachedPromptTokenCount,
                outputTokens: info.generationTokenCount,
                cachedInputTokens: info.cachedPromptTokenCount)))
        }
        let reason: FinishReason = !calls.isEmpty ? .toolCalls : (info?.stopReason == .length ? .length : .completed)
        out.yield(.finished(reason))
    }

    /// MLX gives some models' calls no id, and a counter restarting each turn would repeat ids
    /// across a conversation, so every call gets a unique one.
    static func newCallID() -> String { "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased() }

    /// Reuses last turn's session when this request is exactly its history plus new items.
    private func prepareSession(
        key: Key, request: LLMRequest, split: MLXConversation.Split, loaded: LocalModelRuntime.Loaded
    ) -> (ChatSession, pending: [ConversationItem], Reuse) {
        let current = lock.withLock { live }
        if let current, current.key == key, request.items.count > current.consumed.count,
           Array(request.items.prefix(current.consumed.count)) == current.consumed,
           let suffix = MLXConversation.split(Array(request.items[current.consumed.count...])),
           suffix.history.isEmpty {
            return (current.session, suffix.pending, .reused(newItems: suffix.pending.count))
        }

        let session = ChatSession(
            loaded.container,
            instructions: request.system.isEmpty ? nil : request.system,
            history: MLXConversation.messages(split.history),
            generateParameters: GenerateParameters(maxTokens: settings.maxTokens, temperature: settings.temperature, topP: settings.topP),
            additionalContext: ["enable_thinking": key.thinking],
            tools: MLXBridge.toolSpecs(request.tools))
        return (session, split.pending, .rebuilt)
    }
}
