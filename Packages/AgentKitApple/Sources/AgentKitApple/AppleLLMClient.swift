import AgentKit
import Foundation
import FoundationModels

/// Runs Apple's foundation model (on this Mac, or on Private Cloud Compute) as an `LLMClient`.
///
/// The framework keeps the conversation and runs tools itself; `AppleSessionHost` makes that look like
/// AgentKit's turns. See `Packages/AgentKitApple/CLAUDE.md`.
public final class AppleLLMClient: LLMClient, Sendable {
    public let kind: AppleModelKind
    let host: AppleSessionHost

    public var providerID: String { kind == .onDevice ? "apple" : "apple-pcc" }

    /// `ToolChoice.disabled` needs macOS 27's `toolCallingMode`; before it the closing turn is sent with no tools.
    public var supportsDisabledToolChoice: Bool {
        if #available(macOS 27, *) { true } else { false }
    }

    public init(kind: AppleModelKind) {
        self.kind = kind
        host = AppleSessionHost(kind: kind) { AppleLanguageModelSource($0) }
    }

    init(kind: AppleModelKind, makeSource: @escaping AppleSessionHost.SourceFactory, settle: Duration = .milliseconds(30)) {
        self.kind = kind
        host = AppleSessionHost(kind: kind, settle: settle, makeSource: makeSource)
    }

    /// Frees the session.
    public func resetSession() {
        Task { await host.reset() }
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let task = Task {
                do {
                    try await preflight(request)
                    guard !Task.isCancelled else { return }
                    await host.begin(request, id: id, sink: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [host] _ in
                task.cancel()
                Task { await host.cancel(id) }
            }
        }
    }

    /// Thrown before anything is sent, so the session can compact and retry.
    private func preflight(_ request: LLMRequest) async throws {
        if let message = AppleModelAvailability.message(for: kind) {
            throw LLMError.api(message: message, code: nil)
        }
        let window = [request.contextWindow, await AppleModelAvailability.contextSize(for: kind)].compactMap { $0 }.filter { $0 > 0 }.min()
        if let window, AppleContextFit.exceeds(request, window: window) { throw LLMError.contextLengthExceeded }
    }
}

/// Whether a prompt's estimated size leaves the model too little room to answer. The estimate is the one
/// the session compacts with, so a request that trips this is the one compaction would shrink.
public enum AppleContextFit {
    public static func exceeds(_ request: LLMRequest, window: Int) -> Bool {
        guard window > 0 else { return false }
        let prompt = ContextBudget.tokens(system: request.system, tools: request.tools) + ContextBudget.tokens(request.items)
        return prompt > window - window / 8
    }
}
