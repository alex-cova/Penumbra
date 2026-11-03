import AgentKit
import Testing
@testable import Umbra

@Suite struct IDEAgentRetryStatusTests {
    @Test func aShortWaitJustSaysRetrying() {
        #expect(IDEAgentToolSummary.retryStatus(attempt: 1, delay: 0.8) == "Retrying…")
    }

    @Test func aLongerWaitSaysHowLongAndWhichTry() {
        #expect(IDEAgentToolSummary.retryStatus(attempt: 3, delay: 8) == "The provider is busy or unreachable. Retrying in 8 s (try 3)…")
        #expect(IDEAgentToolSummary.retryStatus(attempt: 2, delay: 120) == "The provider is busy or unreachable. Retrying in 2 min (try 2)…")
    }

    @Test func aSpentRateLimitIsNamedInsteadOfCallingTheProviderBusy() {
        let spent = RateLimitStatus(limitRequests: 3000, remainingRequests: 0, limitTokens: 4_000_000, remainingTokens: 3_000_000)
        #expect(IDEAgentToolSummary.retryStatus(attempt: 1, delay: 12, rateLimit: spent)
            == "The provider's requests rate limit is used up. Retrying in 12 s (try 1)…")
        let tokens = RateLimitStatus(remainingRequests: 10, remainingTokens: 0)
        #expect(IDEAgentToolSummary.retryStatus(attempt: 2, delay: 20, rateLimit: tokens).contains("tokens rate limit"))
        let fine = RateLimitStatus(remainingRequests: 5, remainingTokens: 5)
        #expect(IDEAgentToolSummary.retryStatus(attempt: 3, delay: 8, rateLimit: fine) == "The provider is busy or unreachable. Retrying in 8 s (try 3)…")
    }
}
