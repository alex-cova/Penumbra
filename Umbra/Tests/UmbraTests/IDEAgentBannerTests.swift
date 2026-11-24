import AgentKit
import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDEAgentBannerTests: XCTestCase {
    private func makeConversation() -> IDEAgentConversation {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.banners.\(UUID().uuidString)")!,
            keyStore: IDEAgentMemoryKeyStore())
        return IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
    }

    // MARK: Pending decision

    func testThePendingDecisionIsTheFirstOpenRequestAndClearsWhenAnswered() {
        let chat = makeConversation()
        XCTAssertNil(chat.pendingDecision)
        chat.handle(.toolCallStarted(id: "a", name: "run_command"))
        chat.handle(.toolCallStarted(id: "b", name: "ask_user"))
        chat.handle(.approvalRequested(ApprovalRequest(title: "Run", command: "ls", callID: "a", toolName: "run_command")))
        chat.handle(.questionAsked(UserQuestion(callID: "b", question: "Which?")))
        XCTAssertEqual(chat.pendingDecision?.callID, "a")

        chat.handle(.toolCallFinished(id: "a", name: "run_command", output: ToolOutput("ok")))
        XCTAssertEqual(chat.pendingDecision?.callID, "b")

        chat.handle(.toolCallFinished(id: "b", name: "ask_user", output: ToolOutput("A")))
        XCTAssertNil(chat.pendingDecision)
        XCTAssertFalse(chat.isAwaitingUser)
    }

    // MARK: Retry state

    func testAScheduledRetryShowsAsABannerUntilTheResentRequestAnswers() {
        let chat = makeConversation()
        chat.handle(.rateLimit(RateLimitStatus(limitRequests: 50, remainingRequests: 0)))
        chat.handle(.turnRestarted)
        chat.handle(.retryScheduled(attempt: 2, delay: 12))
        let state = try? XCTUnwrap(chat.retryState)
        XCTAssertEqual(state?.attempt, 2)
        XCTAssertEqual(state?.exhaustedLimit, "requests")
        XCTAssertEqual(state?.title, "The provider's requests rate limit is used up")

        chat.handle(.textDelta("Hello"))
        XCTAssertNil(chat.retryState)
        XCTAssertEqual(chat.status, "Thinking…")
    }

    func testAnotherRetryReplacesTheWaitAndTheEndOfTheRunClearsIt() {
        let chat = makeConversation()
        chat.handle(.retryScheduled(attempt: 1, delay: 2))
        chat.handle(.turnRestarted)
        chat.handle(.retryScheduled(attempt: 2, delay: 8))
        XCTAssertEqual(chat.retryState?.attempt, 2)
        XCTAssertNil(chat.retryState?.exhaustedLimit)
        XCTAssertEqual(chat.retryState?.title, "The provider is busy or unreachable")

        chat.handle(.runEnded(.stopped))
        XCTAssertNil(chat.retryState)
    }

    func testTheCountdownSaysHowLongAndWhichTry() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let state = IDEAgentRetryState(attempt: 3, nextAttemptAt: start.addingTimeInterval(12), exhaustedLimit: nil)
        XCTAssertEqual(state.countdown(now: start), "Retrying in 12 s (try 3)")
        XCTAssertEqual(state.countdown(now: start.addingTimeInterval(11.5)), "Retrying in 1 s (try 3)")
        XCTAssertEqual(state.countdown(now: start.addingTimeInterval(12)), "Retrying now…")
        let long = IDEAgentRetryState(attempt: 1, nextAttemptAt: start.addingTimeInterval(150), exhaustedLimit: "tokens")
        XCTAssertEqual(long.countdown(now: start), "Retrying in 3 min (try 1)")
    }

    // MARK: Retry Now

    func testRetryNowSendsTheWaitingRequestAtOnce() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer { IDEWorkspace.isSessionPersistenceEnabled = true }
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("retry-now-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let workspace = IDEWorkspace()
        workspace.project.setRoot(project)
        defer { workspace.teardown() }

        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.retry.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let transport = RateLimitedOnceTransport()
        let client = OpenAIResponsesClient.meta(
            transport: transport, retry: RetryPolicy(maxRetries: 2, baseDelay: 30, maxDelay: 30, jitter: false))
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()

        controller.draft = "hi"
        controller.submit()
        for _ in 0..<500 where controller.selected.retryState == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.selected.retryState?.exhaustedLimit, "requests")
        XCTAssertEqual(controller.selected.retryState?.countdown(now: Date()).hasPrefix("Retrying in 30 s"), true)

        let start = Date()
        // The client starts waiting just after it reports the retry; ask until the wait is there.
        for _ in 0..<200 where transport.requestCount < 2 {
            controller.retryNow()
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<500 where controller.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.selected.retryState)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(controller.selected.entries.last { $0.kind == .assistant }?.text, "Hello")
    }
}

/// A Responses endpoint that is rate limited for 30 s on the first request and answers the second.
private final class RateLimitedOnceTransport: LLMTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int { lock.withLock { count } }

    func open(_ request: URLRequest) async throws -> LLMHTTPResponse {
        let attempt = lock.withLock { count += 1; return count }
        let lines: [String]
        let response: LLMHTTPResponse
        if attempt == 1 {
            lines = [#"{"error":{"message":"slow down"}}"#]
            response = LLMHTTPResponse(
                status: 429, headers: ["retry-after": "30", "x-ratelimit-remaining-requests": "0"], lines: Self.stream(lines))
        } else {
            lines = [
                #"data: {"type":"response.output_text.delta","delta":"Hello"}"#,
                #"data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}"#,
            ]
            response = LLMHTTPResponse(status: 200, lines: Self.stream(lines))
        }
        return response
    }

    private static func stream(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}
