import AgentKit
import Foundation
import FoundationModels
import Testing
@testable import AgentKitApple

/// A response source whose answers are scripted, so the host's turn logic is tested without a model.
final class ScriptedSource: AppleResponseSource, @unchecked Sendable {
    typealias Script = @Sendable (_ prompt: String, _ invoke: AppleToolInvoker, _ say: @Sendable (String) -> Void) async throws -> Void

    let config: AppleSourceConfig
    private let script: Script
    private let lock = NSLock()
    private var recorded: [(prompt: String, disallowTools: Bool)] = []

    init(config: AppleSourceConfig, script: @escaping Script) {
        self.config = config
        self.script = script
    }

    var prompts: [String] { lock.withLock { recorded.map(\.prompt) } }
    var disallowFlags: [Bool] { lock.withLock { recorded.map(\.disallowTools) } }

    func respond(to prompt: String, disallowTools: Bool) -> AsyncThrowingStream<AppleSnapshot, Error> {
        lock.withLock { recorded.append((prompt, disallowTools)) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await script(prompt, config.invoker) { continuation.yield(AppleSnapshot(text: $0, usage: nil)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class SourceBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sources: [ScriptedSource] = []
    func add(_ source: ScriptedSource) { lock.withLock { sources.append(source) } }
    var all: [ScriptedSource] { lock.withLock { sources } }
}

private let readFile = ToolDefinition(name: "read_file", description: "Reads a file", parameters: [ToolParameter("path", .string, "The path")])

private func request(_ items: [ConversationItem], tools: [ToolDefinition] = [readFile], system: String = "sys", disabled: Bool = false) -> LLMRequest {
    LLMRequest(model: "system", system: system, items: items, tools: tools, toolChoice: disabled ? .disabled : nil)
}

private func makeHost(_ box: SourceBox, script: @escaping ScriptedSource.Script) -> AppleSessionHost {
    AppleSessionHost(kind: .onDevice, settle: .milliseconds(20)) { config in
        let source = ScriptedSource(config: config, script: script)
        box.add(source)
        return source
    }
}

private func run(_ host: AppleSessionHost, _ request: LLMRequest) async throws -> [LLMEvent] {
    let id = UUID()
    let stream = AsyncThrowingStream<LLMEvent, Error> { continuation in
        Task { await host.begin(request, id: id, sink: continuation) }
    }
    var events: [LLMEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func text(_ events: [LLMEvent]) -> String {
    events.compactMap { if case .textDelta(let value) = $0 { value } else { nil } }.joined()
}

private func finish(_ events: [LLMEvent]) -> FinishReason? {
    events.compactMap { if case .finished(let reason) = $0 { reason } else { nil } }.last
}

private func calls(_ events: [LLMEvent]) -> [(id: String, name: String, arguments: String)] {
    events.compactMap { if case .toolCallFinished(let id, let name, let arguments) = $0 { (id, name, arguments) } else { nil } }
}

@Suite struct AppleSessionHostTests {
    @Test func cumulativeSnapshotsBecomeDeltas() async throws {
        let box = SourceBox()
        let host = makeHost(box) { _, _, say in
            say("Hel"); say("Hello"); say("Hello, world")
        }
        let events = try await run(host, request([.user("hi")]))
        #expect(text(events) == "Hello, world")
        #expect(finish(events) == .completed)
        #expect(events.contains { if case .usage = $0 { true } else { false } })
        #expect(box.all.count == 1)
        #expect(box.all[0].prompts == ["hi"])
    }

    @Test func aToolCallEndsTheTurnAndTheOutputResumesTheSameResponse() async throws {
        let box = SourceBox()
        let host = makeHost(box) { _, invoke, say in
            say("Let me look.")
            let output = try await invoke("read_file", #"{"path":"a.txt"}"#)
            say("Let me look. It says \(output).")
        }
        let first = try await run(host, request([.user("read a.txt")]))
        #expect(text(first) == "Let me look.")
        #expect(finish(first) == .toolCalls)
        let made = calls(first)
        #expect(made.count == 1)
        #expect(made[0].name == "read_file")
        #expect(made[0].arguments == #"{"path":"a.txt"}"#)

        let items: [ConversationItem] = [
            .user("read a.txt"), .assistant("Let me look."),
            .toolCall(id: made[0].id, name: "read_file", arguments: made[0].arguments),
            .toolOutput(callID: made[0].id, output: "hello"),
        ]
        let second = try await run(host, request(items))
        #expect(text(second) == " It says hello.")
        #expect(finish(second) == .completed)
        #expect(box.all.count == 1)
        #expect(box.all[0].prompts == ["read a.txt"])
        #expect(await host.lastReuse == .resumedTools)
    }

    @Test func textThatRestartsAfterAToolCallIsNotLost() async throws {
        let box = SourceBox()
        let host = makeHost(box) { _, invoke, say in
            say("Checking.")
            _ = try await invoke("read_file", #"{"path":"a"}"#)
            say("Done.")
        }
        let first = try await run(host, request([.user("go")]))
        let id = calls(first)[0].id
        let second = try await run(host, request([
            .user("go"), .assistant("Checking."), .toolCall(id: id, name: "read_file", arguments: #"{"path":"a"}"#),
            .toolOutput(callID: id, output: "x"),
        ]))
        #expect(text(second) == "Done.")
    }

    @Test func callsMadeTogetherShareOneTurn() async throws {
        let box = SourceBox()
        let host = makeHost(box) { _, invoke, say in
            async let one = invoke("read_file", #"{"path":"a"}"#)
            async let two = invoke("read_file", #"{"path":"b"}"#)
            let (a, b) = try await (one, two)
            say("\(a)+\(b)")
        }
        let first = try await run(host, request([.user("go")]))
        let made = calls(first)
        #expect(made.count == 2)
        #expect(finish(first) == .toolCalls)
        let items: [ConversationItem] = [.user("go")]
            + made.map { .toolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
            + made.map { .toolOutput(callID: $0.id, output: $0.arguments.contains(#":"a""#) ? "A" : "B") }
        let second = try await run(host, request(items))
        #expect(text(second) == "A+B")
    }

    @Test func aNewUserMessageAfterAnAnswerContinuesTheSession() async throws {
        let box = SourceBox()
        let host = makeHost(box) { prompt, _, say in say("re: \(prompt)") }
        _ = try await run(host, request([.user("one")]))
        let second = try await run(host, request([.user("one"), .assistant("re: one"), .user("two")]))
        #expect(text(second) == "re: two")
        #expect(box.all.count == 1)
        #expect(box.all[0].prompts == ["one", "two"])
        #expect(await host.lastReuse == .continued)
    }

    @Test func aChangedToolListStartsANewSession() async throws {
        let box = SourceBox()
        let host = makeHost(box) { prompt, _, say in say(prompt) }
        _ = try await run(host, request([.user("one")]))
        _ = try await run(host, request([.user("one"), .assistant("one"), .user("two")], tools: []))
        #expect(box.all.count == 2)
        #expect(await host.lastReuse == .rebuilt)
    }

    @Test func anItemTheLoopInsertedStartsANewSessionAndFailsTheOldCalls() async throws {
        let box = SourceBox()
        let cancelled = Flag()
        let host = makeHost(box) { _, invoke, say in
            do {
                _ = try await invoke("read_file", #"{"path":"a"}"#)
            } catch {
                cancelled.set()
                throw error
            }
            say("never")
        }
        let first = try await run(host, request([.user("go")]))
        let id = calls(first)[0].id
        let items: [ConversationItem] = [
            .user("go"), .toolCall(id: id, name: "read_file", arguments: #"{"path":"a"}"#),
            .toolOutput(callID: id, output: "x"), .user("[note] queued"),
        ]
        _ = try? await run(host, request(items))
        #expect(box.all.count == 2)
        // The rebuilt session was handed the whole history in one prompt.
        #expect(box.all[1].prompts == ["[note] queued"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(cancelled.value)
    }

    @Test func aTranscriptEndingInToolOutputIsSentAsOnePrompt() async throws {
        let box = SourceBox()
        let host = makeHost(box) { _, _, say in say("ok") }
        let items: [ConversationItem] = [
            .user("go"), .assistant("Looking."), .toolCall(id: "c1", name: "read_file", arguments: #"{"path":"a"}"#),
            .toolOutput(callID: "c1", output: "contents"),
        ]
        let events = try await run(host, request(items))
        #expect(text(events) == "ok")
        let prompt = box.all[0].prompts[0]
        #expect(prompt.contains("[read_file]"))
        #expect(prompt.contains("contents"))
    }

    @Test func stoppingFailsTheCallTheModelIsWaitingOn() async throws {
        let box = SourceBox()
        let cancelled = Flag()
        let host = makeHost(box) { _, invoke, _ in
            do { _ = try await invoke("read_file", "{}") } catch { cancelled.set(); throw error }
        }
        let id = UUID()
        let stream = AsyncThrowingStream<LLMEvent, Error> { continuation in
            Task { await host.begin(request([.user("go")]), id: id, sink: continuation) }
        }
        var sawCall = false
        for try await event in stream {
            if case .toolCallFinished = event { sawCall = true }
            if case .finished = event { break }
        }
        #expect(sawCall)
        await host.cancel(id)
        // The turn had already ended, so a cancel for it is a no-op and the call is still waiting.
        #expect(!cancelled.value)
        await host.reset()
        try await Task.sleep(for: .milliseconds(100))
        #expect(cancelled.value)
    }

    @Test func closingTurnsCanDisallowTools() async throws {
        let box = SourceBox()
        let host = makeHost(box) { _, _, say in say("done") }
        _ = try await run(host, request([.user("go")], disabled: true))
        #expect(box.all[0].disallowFlags == [true])
    }

    @Test func aRateLimitReachesTheLoopAsAnLLMError() async throws {
        let box = SourceBox()
        let host = makeHost(box) { _, _, _ in throw LLMError.rateLimited(retryAfter: 5) }
        await #expect(throws: LLMError.rateLimited(retryAfter: 5)) { try await run(host, request([.user("go")])) }
    }

    @Test func aConversationThatEndsInAnAssistantMessageIsRefused() async throws {
        let box = SourceBox()
        let host = makeHost(box) { _, _, _ in }
        await #expect(throws: LLMError.self) { try await run(host, request([.user("go"), .assistant("hi")])) }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
