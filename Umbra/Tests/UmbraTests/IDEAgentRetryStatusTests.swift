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
}
