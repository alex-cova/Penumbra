import Foundation
import Testing
@testable import AgentKit

/// Opt-in, against a real Ollama: `AGENTKIT_OLLAMA_MODEL=qwen-fixed:latest swift test --filter OllamaSmokeTests`.
/// Needs a model with tool support. These check the wire, not the model's intelligence.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTKIT_OLLAMA_MODEL"] != nil), .serialized)
struct OllamaSmokeTests {
    private var model: String { ProcessInfo.processInfo.environment["AGENTKIT_OLLAMA_MODEL"] ?? "" }
    private var client: OllamaClient { OllamaClient(contextLength: 8_192, supportsThinking: false) }

    @Test func listsTheInstalledModelWithItsCapabilities() async throws {
        let models = try await OllamaModelCatalog().models()
        let ours = try #require(models.first { $0.name == model })
        #expect(ours.supportsTools, "this smoke test needs a model with tool support")
        #expect(ours.contextLength != nil)
    }

    @Test func streamsRealText() async throws {
        let events = try await collect(client.stream(LLMRequest(model: model, items: [.user("Reply with exactly the word: pong")], maxOutputTokens: 40)))
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text.lowercased().contains("pong"), "\(text)")
        #expect(events.last == .finished(.completed))
        let usage = events.compactMap { event -> TokenUsage? in if case .usage(let u) = event { u } else { nil } }.first
        #expect((usage?.inputTokens ?? 0) > 0 && (usage?.outputTokens ?? 0) > 0)
    }

    @Test func aRealToolCallRoundTripThroughTheSession() async throws {
        let project = try TempProject(files: ["NOTES.md": "The secret word is PELICAN.\n"])
        let session = AgentSession(
            client: client, tools: ReadOnlyTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(model: model, systemPrompt: SystemPrompt.make(projectRoot: project.workspace.rootPath), maxOutputTokens: 600))
        var events: [AgentEvent] = []
        for await event in await session.send("Read NOTES.md with the read_file tool and tell me the secret word.") { events.append(event) }

        #expect(events.last == .runEnded(.completed), "\(events.suffix(3))")
        let usedRead = events.contains { if case .toolCallStarted(_, "read_file") = $0 { true } else { false } }
        #expect(usedRead, "the model should have called read_file")
        let answer = events.compactMap { if case .assistantMessage(let t) = $0 { t } else { nil } }.joined(separator: " ")
        #expect(answer.uppercased().contains("PELICAN"), "\(answer)")
        expectEveryCallAnswered(await session.items)
    }

    /// The Chat Completions client against Ollama's OpenAI-compatible `/v1`, as it would run against LM Studio.
    @Test func theChatCompletionsClientWorksAgainstOllamasCompatibleEndpoint() async throws {
        let endpoint = LLMEndpoint(baseURL: URL(string: "http://localhost:11434/v1")!)
        let chat = OpenAIChatCompletionsClient(endpoint: endpoint, capabilities: .compatible)
        let text = try await collect(chat.stream(LLMRequest(model: model, items: [.user("Reply with exactly the word: pong")], maxOutputTokens: 200)))
        #expect(text.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined().lowercased().contains("pong"))
        #expect(text.last == .finished(.completed) || text.last == .finished(.length))

        let project = try TempProject(files: ["NOTES.md": "The secret word is HERON.\n"])
        let session = AgentSession(
            client: chat, tools: ReadOnlyTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(model: model, systemPrompt: SystemPrompt.make(projectRoot: project.workspace.rootPath), maxOutputTokens: 1_500))
        var events: [AgentEvent] = []
        for await event in await session.send("Read NOTES.md with the read_file tool and tell me the secret word.") { events.append(event) }
        #expect(events.contains { if case .toolCallStarted(_, "read_file") = $0 { true } else { false } })
        let answer = events.compactMap { if case .assistantMessage(let t) = $0 { t } else { nil } }.joined(separator: " ")
        #expect(answer.uppercased().contains("HERON"), "\(answer)")
        expectEveryCallAnswered(await session.items)
    }

    /// A conversation that outgrows a deliberately small window: old tool output is cleared and the
    /// oldest part summarized by the same real model, and the session keeps working afterwards.
    @Test func aLongSessionCompactsAndKeepsAnswering() async throws {
        var files: [String: String] = [:]
        for index in 1...6 {
            let filler = (1...40).map { "Line \($0) of chapter \(index): the quick brown fox jumps over the lazy dog." }.joined(separator: "\n")
            files["chapter\(index).txt"] = "The code word of chapter \(index) is WORD\(index)ZED.\n" + filler + "\n"
        }
        let project = try TempProject(files: files)
        let session = AgentSession(
            client: client, tools: ReadOnlyTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(
                model: model, systemPrompt: SystemPrompt.make(projectRoot: project.workspace.rootPath),
                maxOutputTokens: 600, contextWindow: 4_000, compactionThreshold: 0.6))
        var reports: [CompactionReport] = []
        var endings: [RunEnding] = []
        for index in 1...6 {
            for await event in await session.send("Read chapter\(index).txt with read_file and tell me its code word in one short sentence.") {
                if case .compacted(let report) = event { reports.append(report) }
                if case .runEnded(let ending) = event { endings.append(ending) }
            }
        }
        #expect(endings.allSatisfy { $0 == .completed }, "\(endings)")
        #expect(reports.contains { $0.changedAnything }, "a window of 4000 tokens must have forced compaction")
        #expect(reports.allSatisfy { $0.estimatedTokensAfter < $0.estimatedTokensBefore || !$0.changedAnything }, "compaction must shrink the context")
        expectEveryCallAnswered(await session.items)

        var answer = ""
        for await event in await session.send("Without reading anything again: which chapters' code words have you told me so far? List the words.") {
            if case .assistantMessage(let text) = event { answer += text }
        }
        // What the model remembers is the model's business; the run must simply still work.
        print("compactions: \(reports)\nrecall after compaction: \(answer)")
        #expect(!answer.isEmpty)
    }

    /// Stop must close the connection: Ollama then abandons the generation, so the next request is
    /// not queued behind a long answer nobody is reading.
    @Test func cancellingTheStreamEndsItPromptlyAndFreesTheServer() async throws {
        let long = LLMRequest(model: model, items: [.user("Count from 1 to 500, one number per line, nothing else.")], maxOutputTokens: 2_000)
        let started = Date()
        let task = Task { () -> Int in
            var count = 0
            do { for try await _ in client.stream(long) { count += 1; if count == 5 { throw CancellationError() } } } catch {}
            return count
        }
        let received = await task.value
        #expect(received >= 5)
        #expect(Date().timeIntervalSince(started) < 10, "the client side ended promptly")

        let next = Date()
        let events = try await collect(client.stream(LLMRequest(model: model, items: [.user("Reply with exactly: ok")], maxOutputTokens: 20)))
        #expect(events.last == .finished(.completed) || events.last == .finished(.length))
        #expect(Date().timeIntervalSince(next) < 15, "the abandoned generation must not hold the server")
    }

    @Test func anUnknownModelIsReportedNotRetried() async throws {
        await #expect(throws: LLMError.self) {
            _ = try await collect(client.stream(LLMRequest(model: "definitely-not-installed:1b", items: [.user("hi")])))
        }
    }
}
