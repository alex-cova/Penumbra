import AgentKit
import Testing
@testable import AgentKitMLX

@Suite struct MLXContextFitTests {
    @Test func aPromptPastTheGivenWindowDoesNotFit() {
        let request = LLMRequest(model: "m", system: String(repeating: "a", count: 4_000), items: [.user("hi")])
        #expect(MLXContextFit.exceeds(request, window: 10))
        #expect(!MLXContextFit.exceeds(request, window: 100_000))
        #expect(!MLXContextFit.exceeds(request, window: 0), "an unknown window is not treated as overflow")
    }
}
