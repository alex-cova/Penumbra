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
}
