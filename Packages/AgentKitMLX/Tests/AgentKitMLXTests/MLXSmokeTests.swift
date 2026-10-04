import AgentKit
import Foundation
import LocalModelStore
import Testing
@testable import AgentKitMLX

/// End to end against the real Hugging Face and a real MLX model on this Mac's GPU. Opt-in, because
/// it downloads a model (once; kept in `~/Library/Caches/AgentKitMLXTests`) and runs inference:
///
///     AGENTKIT_MLX_SMOKE=1 swift test --filter MLXSmokeTests
///
/// `AGENTKIT_MLX_MODEL` picks another repository. It must be a model whose chat template takes tools.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AGENTKIT_MLX_SMOKE"] != nil))
struct MLXSmokeTests {
    /// `swift test` runs inside Xcode's test helper, not next to the build products, so MLX is told
    /// where the test bundle's resources (which hold the Metal library) are.
    static let configured: Void = {
        LocalModelRuntime.extraMetalSearchRoots = MLXTestEnvironment.resourceRoots()
    }()

    init() { _ = Self.configured }

    static let modelID = ProcessInfo.processInfo.environment["AGENTKIT_MLX_MODEL"] ?? "mlx-community/Qwen2.5-3B-Instruct-4bit"

    static let paths: LocalModelPaths = {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentKitMLXTests/Models", isDirectory: true)
        return LocalModelPaths(root: root)
    }()

    /// Downloads the model unless it is already installed.
    static func installedModel() async throws -> InstalledLocalModel {
        try paths.createDirectories()
        if let existing = LocalModelCatalog(paths: paths).installed().first(where: { $0.id == modelID }) { return existing }
        return try await LocalModelDownloader().download(id: modelID, into: paths, progress: { _ in })
    }

    private func collect(_ stream: AsyncThrowingStream<LLMEvent, Error>) async throws -> [LLMEvent] {
        var events: [LLMEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func theLibraryIsFoundSoMLXWillNotCrash() {
        #expect(MLXAvailability.currentStatus() == .available, "\(MLXAvailability.message(for: MLXAvailability.currentStatus()))")
    }

    @Test func searchFindsTheModelOnTheLiveHub() async throws {
        let results = try await HuggingFaceSearchEngine.search(query: Self.modelID.split(separator: "/").last.map(String.init) ?? "Qwen")
        #expect(results.contains { $0.id == Self.modelID }, "\(results.map(\.id))")
        let info = try await HuggingFaceSearchEngine.repositoryInfo(id: Self.modelID)
        #expect(info.siblings.contains { $0.path.hasSuffix(".safetensors") })
        let template = await ChatTemplate.fetch(id: Self.modelID)
        #expect(template.map(ChatTemplate.supportsTools) == true, "the agent needs a template that takes tools")
    }

    @Test func downloadsLoadsAndInspectsTheModel() async throws {
        let model = try await Self.installedModel()
        let loaded = try await LocalModelRuntime.shared.load(model)
        #expect(loaded.info.supportsTools)
        #expect((loaded.info.contextLength ?? 0) >= 4_096)
        #expect(await LocalModelRuntime.shared.memoryBytes() > 100_000_000, "weights are resident")
    }

    @Test func streamsRealTextAndReportsUsage() async throws {
        let model = try await Self.installedModel()
        let client = MLXLLMClient(model: model, settings: MLXGenerationSettings(temperature: 0, maxTokens: 40))
        let events = try await collect(client.stream(LLMRequest(model: model.id, items: [.user("Reply with exactly the single word: pong")])))
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text.lowercased().contains("pong"), "\(text)")
        #expect(events.last == .finished(.completed) || events.last == .finished(.length))
        let usage = events.compactMap { event -> TokenUsage? in if case .usage(let u) = event { u } else { nil } }.first
        #expect((usage?.inputTokens ?? 0) > 0 && (usage?.outputTokens ?? 0) > 0)
        #expect(usage?.cachedInputTokens == 0, "the first turn has nothing cached")
    }

    @Test func aRealToolCallRoundTripReusesTheKVCacheOnTheSecondTurn() async throws {
        let model = try await Self.installedModel()
        let project = try TempProject(files: ["NOTES.md": "The secret word is PELICAN.\n"])
        let client = MLXLLMClient(model: model, settings: MLXGenerationSettings(temperature: 0, maxTokens: 400))
        let session = AgentSession(
            client: client, tools: ReadOnlyTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(model: model.id, systemPrompt: SystemPrompt.make(projectRoot: project.workspace.rootPath)))

        var events: [AgentEvent] = []
        for await event in await session.send("Read NOTES.md with the read_file tool and tell me the secret word.") { events.append(event) }

        #expect(events.last == .runEnded(.completed), "\(events.suffix(3))")
        #expect(events.contains { if case .toolCallStarted(_, "read_file") = $0 { true } else { false } }, "the model should call read_file")
        let answer = events.compactMap { if case .assistantMessage(let t) = $0 { t } else { nil } }.joined(separator: " ")
        #expect(answer.uppercased().contains("PELICAN"), "\(answer)")
        expectEveryCallAnswered(await session.items)

        // Turn 1 built the session; turn 2 (after the tool result) sent only the new items.
        #expect(client.lastCacheUse == .reused(newItems: 1))
        let usages = events.compactMap { event -> TokenUsage? in if case .usage(let u) = event { u } else { nil } }
        try #require(usages.count >= 2, "two model turns were expected, got \(usages.count)")
        #expect(usages[0].cachedInputTokens == 0)
        #expect(usages[1].cachedInputTokens > 0, "the second turn should be served from the cache")
        #expect(usages[1].inputTokens > usages[0].inputTokens, "and still count the whole prompt as context")
    }

    @Test func aFollowUpMessageAfterAnAnswerAlsoReusesTheCache() async throws {
        let model = try await Self.installedModel()
        let client = MLXLLMClient(model: model, settings: MLXGenerationSettings(temperature: 0, maxTokens: 60))
        let first = try await collect(client.stream(LLMRequest(model: model.id, items: [.user("My name is Ada. Reply with just OK.")])))
        let answer = first.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        let second = try await collect(client.stream(LLMRequest(
            model: model.id, items: [.user("My name is Ada. Reply with just OK."), .assistant(answer), .user("What is my name? One word.")])))
        #expect(client.lastCacheUse == .reused(newItems: 1))
        let text = second.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text.contains("Ada"), "\(text)")
    }

    @Test func historyThatDoesNotMatchStartsFreshWithOneFullPrefill() async throws {
        let model = try await Self.installedModel()
        let client = MLXLLMClient(model: model, settings: MLXGenerationSettings(temperature: 0, maxTokens: 20))
        _ = try await collect(client.stream(LLMRequest(model: model.id, items: [.user("Say hi.")])))
        // As after compaction: earlier history rewritten, so the cached session no longer matches.
        let events = try await collect(client.stream(LLMRequest(model: model.id, items: [.user("A different opening."), .assistant("Noted."), .user("Say ok.")])))
        #expect(client.lastCacheUse == .rebuilt)
        #expect(events.last == .finished(.completed) || events.last == .finished(.length))
    }

    @Test func stoppingMidAnswerEndsPromptlyAndTheNextTurnStartsClean() async throws {
        let model = try await Self.installedModel()
        let client = MLXLLMClient(model: model, settings: MLXGenerationSettings(temperature: 0.7, maxTokens: 2_000))
        let started = Date()
        let task = Task { () -> Int in
            var chunks = 0
            do {
                for try await event in client.stream(LLMRequest(model: model.id, items: [.user("Count from 1 to 500, one number per line.")])) {
                    if case .textDelta = event { chunks += 1 }
                    if chunks == 5 { throw CancellationError() }
                }
            } catch {}
            return chunks
        }
        #expect(await task.value >= 5)
        #expect(Date().timeIntervalSince(started) < 20, "stopping must not wait for the whole answer")

        let events = try await collect(client.stream(LLMRequest(model: model.id, items: [.user("Reply with exactly: ok")])))
        #expect(client.lastCacheUse == .rebuilt, "a stopped turn leaves nothing to reuse")
        #expect(events.contains { if case .textDelta = $0 { true } else { false } })
    }
}

/// A throwaway project folder.
final class TempProject: @unchecked Sendable {
    let root: URL
    init(files: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentkitmlx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    var workspace: DiskAgentWorkspace { DiskAgentWorkspace(root: root) }
}

func expectEveryCallAnswered(_ items: [ConversationItem]) {
    var calls: [String] = []
    var outputs: [String] = []
    for item in items {
        if case .toolCall(let id, _, _) = item { calls.append(id) }
        if case .toolOutput(let id, _) = item { outputs.append(id) }
    }
    #expect(calls.sorted() == outputs.sorted())
}
