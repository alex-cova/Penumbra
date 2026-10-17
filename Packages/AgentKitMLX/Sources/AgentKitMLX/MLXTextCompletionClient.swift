import Foundation
import LocalModelStore
import MLX
import MLXLMCommon

/// A raw text completion request: no chat template, the prompt is fed to the model as-is.
public struct TextCompletionRequest: Sendable {
    public var prompt: String
    public var maxTokens: Int
    public var stop: [String]
    public var temperature: Float

    public init(prompt: String, maxTokens: Int, stop: [String] = [], temperature: Float = 0) {
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.stop = stop
        self.temperature = temperature
    }
}

/// Streams raw completions from an installed local model, for full-line code completion.
/// Lives in this module because `LocalModelRuntime.Loaded.container` is internal.
public final class MLXTextCompletionClient: Sendable {
    private let runtime: LocalModelRuntime
    private let model: InstalledLocalModel

    public init(runtime: LocalModelRuntime, model: InstalledLocalModel) {
        self.runtime = runtime
        self.model = model
    }

    /// Text deltas. Cancellation stops generation.
    public func complete(_ request: TextCompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: TextCompletionRequest,
        _ continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let loaded = try await runtime.acquire(model)
        do {
            let tokens = await loaded.container.encode(request.prompt)
            let parameters = GenerateParameters(maxTokens: request.maxTokens, temperature: request.temperature)
            let stream = try await loaded.container.generate(
                input: LMInput(tokens: MLXArray(tokens.map(Int32.init))), parameters: parameters
            )
            var filter = TextCompletionStopFilter(stop: request.stop)
            for await generation in stream {
                try Task.checkCancellation()
                guard case .chunk(let text) = generation else { continue }
                let visible = filter.consume(text)
                if !visible.isEmpty { continuation.yield(visible) }
                if filter.stopped { break }
            }
            let leftover = filter.finish()
            if !leftover.isEmpty { continuation.yield(leftover) }
            await runtime.release()
        } catch {
            await runtime.release()
            throw error
        }
    }
}

/// Drops everything from the first stop string on, holding back a tail that could still
/// grow into one (a stop string can be split across chunks). The built-in markers cover
/// EOS spelled as text by base models.
struct TextCompletionStopFilter {
    static let specialMarkers = [
        "<|endoftext|>", "<|file_sep|>", "<|fim_pad|>", "<|repo_name|>",
        "<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>", "<|im_end|>", "<|eot_id|>"
    ]

    private let markers: [String]
    private(set) var stopped = false
    private var held = ""

    init(stop: [String]) {
        markers = stop.filter { !$0.isEmpty } + Self.specialMarkers
    }

    mutating func consume(_ text: String) -> String {
        guard !stopped else { return "" }
        held += text
        if let cut = markers.compactMap({ held.range(of: $0)?.lowerBound }).min() {
            stopped = true
            defer { held = "" }
            return String(held[..<cut])
        }
        let keep = Self.longestMarkerPrefixSuffix(of: held, markers: markers)
        defer { held = String(held.suffix(keep)) }
        return String(held.dropLast(keep))
    }

    mutating func finish() -> String {
        defer { held = "" }
        return stopped ? "" : held
    }

    private static func longestMarkerPrefixSuffix(of text: String, markers: [String]) -> Int {
        var best = 0
        for marker in markers {
            let limit = min(marker.count - 1, text.count)
            guard limit > best else { continue }
            for length in stride(from: limit, to: best, by: -1) where text.hasSuffix(marker.prefix(length)) {
                best = length
                break
            }
        }
        return best
    }
}
