import Foundation
import ImageIO
import Testing
@testable import AgentKit

/// Opt-in, against the real Meta Model API: `AGENTKIT_META_KEY=... swift test --filter MetaSmokeTests`
/// (`AGENTKIT_META_MODEL` picks the model; the default is the current Muse Spark). These spend a few
/// cents and check the wire, not the model's intelligence: Meta speaks the Responses format with a
/// Bearer key, so this is `OpenAIResponsesClient` at `api.meta.ai` — the same client Umbra builds
/// for its Meta provider.
@Suite(.enabled(if: PaidTests.allowed("AGENTKIT_META_KEY")), .serialized)
struct MetaSmokeTests {
    private var model: String { PaidTests.value("AGENTKIT_META_MODEL") ?? "muse-spark-1.3" }
    private var client: OpenAIResponsesClient {
        OpenAIResponsesClient(endpoint: LLMEndpoint(baseURL: LLMEndpoint.meta.baseURL, apiKey: PaidTests.value("AGENTKIT_META_KEY")))
    }

    @Test func streamsRealTextWithUsage() async throws {
        let events = try await collect(client.stream(LLMRequest(
            model: model, items: [.user("Reply with exactly the word: pong")], reasoningEffort: "minimal",
            maxOutputTokens: 4_000)))
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text.lowercased().contains("pong"), "\(text)")
        #expect(events.last == .finished(.completed))
        let usage = events.compactMap { event -> TokenUsage? in if case .usage(let u) = event { u } else { nil } }.first
        #expect((usage?.inputTokens ?? 0) > 0 && (usage?.outputTokens ?? 0) > 0)
    }

    @Test func aRejectedKeyIsReportedAsUnauthorized() async throws {
        let bad = OpenAIResponsesClient(
            endpoint: LLMEndpoint(baseURL: LLMEndpoint.meta.baseURL, apiKey: "not-a-real-key"), retry: .none)
        await #expect(throws: LLMError.unauthorized) {
            _ = try await collect(bad.stream(LLMRequest(model: model, items: [.user("hi")], maxOutputTokens: 20)))
        }
    }

    @Test func aRealToolCallRoundTripThroughTheSession() async throws {
        let project = try TempProject(files: ["NOTES.md": "The secret word is PELICAN.\n"])
        let session = AgentSession(
            client: client, tools: ReadOnlyTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(
                model: model, systemPrompt: SystemPrompt.make(projectRoot: project.workspace.rootPath), reasoningEffort: "low", maxOutputTokens: 4_000))
        var events: [AgentEvent] = []
        for await event in await session.send("Read NOTES.md with the read_file tool and tell me the secret word.") { events.append(event) }

        #expect(events.last == .runEnded(.completed), "\(events.suffix(3))")
        #expect(events.contains { if case .toolCallStarted(_, "read_file") = $0 { true } else { false } })
        let answer = events.compactMap { if case .assistantMessage(let t) = $0 { t } else { nil } }.joined(separator: " ")
        #expect(answer.uppercased().contains("PELICAN"), "\(answer)")
        expectEveryCallAnswered(await session.items)
    }

    // MARK: - Quirks measured on 2026-11-02 (docs/harness/agent-harness-9.md)
    // Each of these pins a way Meta's Model API differs from OpenAI's. If one fails, Meta changed
    // the API: update the matching code (`OpenAIResponsesClient.meta`, `IDEAgentProvider.reasoningEfforts`).

    @Test func toolChoiceNoneIsStillRejected() async throws {
        // Why `OpenAIResponsesClient.meta` reports `supportsDisabledToolChoice == false`.
        let tool = ToolDefinition(name: "look", description: "d", parameters: [])
        await #expect {
            _ = try await collect(client.stream(LLMRequest(
                model: model, items: [.user("hi")], tools: [tool], toolChoice: .disabled, maxOutputTokens: 200)))
        } throws: { error in
            if case LLMError.badRequest(let status, _) = error { return status == 400 }
            return false
        }
    }

    @Test func theClosingTurnOfACappedRunWorksWithoutToolChoiceNone() async throws {
        let project = try TempProject(files: ["NOTES.md": "The secret word is PELICAN.\n"])
        let session = AgentSession(
            client: OpenAIResponsesClient.meta(endpoint: LLMEndpoint(baseURL: LLMEndpoint.meta.baseURL, apiKey: PaidTests.value("AGENTKIT_META_KEY"))),
            tools: ReadOnlyTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(
                model: model, systemPrompt: SystemPrompt.make(projectRoot: project.workspace.rootPath),
                reasoningEffort: "minimal", maxIterations: 1))
        var events: [AgentEvent] = []
        for await event in await session.send("Read NOTES.md with the read_file tool, then tell me the secret word.") { events.append(event) }
        // The cap is one iteration, so the second turn is the closing one; it must not be a 400.
        let failures = events.compactMap { event -> String? in if case .runEnded(.failed(let reason)) = event { reason } else { nil } }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func reasoningNoneIsRejectedAndMinimalToMaxAreAccepted() async throws {
        await #expect {
            _ = try await collect(client.stream(LLMRequest(
                model: model, items: [.user("hi")], reasoningEffort: "none", maxOutputTokens: 2_000)))
        } throws: { error in
            if case LLMError.badRequest(let status, _) = error { return status == 400 }
            return false
        }
        for effort in ["minimal", "low"] {
            let events = try await collect(client.stream(LLMRequest(
                model: model, items: [.user("Reply with exactly the word: pong")], reasoningEffort: effort, maxOutputTokens: 4_000)))
            #expect(events.last == .finished(.completed), "\(effort): \(events.suffix(2))")
        }
    }

    @Test func aSmallPictureIsSeenThroughInputImage() async throws {
        let png = try Self.solidPNG(red: 255, green: 0, blue: 0, side: 64)
        let events = try await collect(client.stream(LLMRequest(
            model: model,
            items: [.userParts([.text("What single colour fills this image? Answer with one word."), .image(id: "red", mediaType: "image/png")])],
            images: ["red": LLMImage(id: "red", mediaType: "image/png", data: png)],
            reasoningEffort: "minimal", maxOutputTokens: 4_000)))
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text.lowercased().contains("red"), "\(text)")
    }

    @Test func aRepeatedPrefixIsServedFromTheCacheAndReported() async throws {
        let filler = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 400)
        let request = LLMRequest(
            model: model, items: [.user(filler + "\nReply with exactly: pong")], reasoningEffort: "minimal",
            maxOutputTokens: 4_000, cacheKey: "agentkit-meta-smoke")
        _ = try await collect(client.stream(request))
        let second = try await collect(client.stream(request))
        let usage = try #require(second.compactMap { event -> TokenUsage? in if case .usage(let u) = event { u } else { nil } }.first)
        #expect(usage.cachedInputTokens > 0, "\(usage)")
    }

    /// 1,048,576 tokens is the window `hostedContextWindows` assumes for `muse-`. An input over it is
    /// rejected before any generation, so this costs nothing; it fails if Meta moves the window or
    /// changes the error that makes compaction run. About 6 MB of hex is over 3 million tokens.
    @Test func anOversizedPromptIsRejectedAsContextOverflowAtTheAssumedWindow() async throws {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        let text = String((0..<(6 * 1024 * 1024)).map { _ in digits[Int(generator.next() % 16)] })
        await #expect {
            _ = try await collect(client.stream(LLMRequest(
                model: model, items: [.user(text + "\nReply: ok")], reasoningEffort: "minimal", maxOutputTokens: 50)))
        } throws: { error in error as? LLMError == .contextLengthExceeded }
    }

    /// A solid-colour PNG made with ImageIO, so the test carries no embedded bytes to get wrong.
    private static func solidPNG(red: UInt8, green: UInt8, blue: UInt8, side: Int) throws -> Data {
        let pixels = [UInt8](repeating: 0, count: side * side * 4).enumerated().map { index, _ -> UInt8 in
            switch index % 4 { case 0: red; case 1: green; case 2: blue; default: 255 }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
