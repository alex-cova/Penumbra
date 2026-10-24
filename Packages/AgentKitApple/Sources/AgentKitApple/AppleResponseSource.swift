import AgentKit
import Foundation
import FoundationModels

/// Runs one of the tools the model was shown. The framework calls this in the middle of a response and
/// waits, so the host can end the turn, let AgentKit's loop approve and run the tool, and answer later.
typealias AppleToolInvoker = @Sendable (_ name: String, _ argumentsJSON: String) async throws -> String

/// One text snapshot of a response. `text` is everything the response has said so far.
struct AppleSnapshot: Sendable {
    var text: String
    /// Cumulative for the response, when the framework reports it (macOS 27).
    var usage: TokenUsage?
}

struct AppleSourceConfig: Sendable {
    var kind: AppleModelKind
    var entries: [Transcript.Entry]
    var tools: [ToolDefinition]
    var invoker: AppleToolInvoker
}

/// The seam between the host's turn logic and the framework, so the host is tested with a fake.
protocol AppleResponseSource: Sendable {
    /// Streams one response. Cancelling the consumer ends it.
    func respond(to prompt: String, disallowTools: Bool) -> AsyncThrowingStream<AppleSnapshot, Error>
}

/// A tool the framework may call, whose work belongs to AgentKit's loop.
struct AppleProxyTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let invoke: AppleToolInvoker

    var includesSchemaInInstructions: Bool { true }

    func call(arguments: GeneratedContent) async throws -> String {
        try await invoke(name, arguments.jsonString)
    }
}

final class AppleLanguageModelSource: AppleResponseSource, @unchecked Sendable {
    private let session: LanguageModelSession

    init(_ config: AppleSourceConfig) {
        let tools: [any Tool] = config.tools.compactMap { definition in
            guard let schema = try? AppleToolSchema.generationSchema(for: definition) else { return nil }
            return AppleProxyTool(name: definition.name, description: definition.description, parameters: schema, invoke: config.invoker)
        }
        let transcript = Transcript(entries: config.entries)
        switch config.kind {
        case .onDevice:
            session = LanguageModelSession(model: SystemLanguageModel.default, tools: tools, transcript: transcript)
        case .privateCloudCompute:
            if #available(macOS 27, *) {
                session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, transcript: transcript)
            } else {
                session = LanguageModelSession(model: SystemLanguageModel.default, tools: tools, transcript: transcript)
            }
        }
    }

    func respond(to prompt: String, disallowTools: Bool) -> AsyncThrowingStream<AppleSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var options = GenerationOptions()
                    if disallowTools, #available(macOS 27, *) { options.toolCallingMode = .disallowed }
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        var usage: TokenUsage?
                        if #available(macOS 27, *) {
                            let reported = snapshot.usage
                            usage = TokenUsage(
                                inputTokens: reported.input.totalTokenCount, outputTokens: reported.output.totalTokenCount,
                                cachedInputTokens: reported.input.cachedTokenCount,
                                reasoningTokens: reported.output.reasoningTokenCount)
                        }
                        continuation.yield(AppleSnapshot(text: snapshot.content, usage: usage))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
