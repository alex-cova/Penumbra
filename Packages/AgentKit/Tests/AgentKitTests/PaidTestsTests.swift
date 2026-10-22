import Testing
@testable import AgentKit

/// The switch that keeps tests that spend money out of CI (`PaidTests.swift`).
@Suite struct PaidTestsTests {
    private let key = "AGENTKIT_OPENAI_KEY"

    @Test func aValueIsUsedOnlyWhenItIsNonEmptyAndNotInCI() {
        #expect(PaidTests.value(key, in: [key: "sk-123"]) == "sk-123")
        #expect(PaidTests.value(key, in: [key: "  sk-123\n"]) == "sk-123")
        #expect(PaidTests.value(key, in: [:]) == nil)
        #expect(PaidTests.value(key, in: [key: ""]) == nil, "a secret that does not exist expands to an empty string")
        #expect(PaidTests.value(key, in: [key: "   "]) == nil)
    }

    @Test func gitHubActionsAndOtherCISwitchEveryPaidTestOff() {
        for ci in [["GITHUB_ACTIONS": "true"], ["CI": "true"], ["CI": "1"], ["CI": "yes"], ["GITHUB_ACTIONS": "true", "CI": "true"]] {
            #expect(PaidTests.isCI(ci), "\(ci)")
            #expect(PaidTests.value(key, in: ci.merging([key: "sk-123"]) { $1 }) == nil, "\(ci)")
        }
    }

    @Test func aCIVariableThatMeansNoDoesNotCount() {
        for notCI in [[:], ["CI": ""], ["CI": "false"], ["CI": "0"], ["GITHUB_ACTIONS": "FALSE"]] as [[String: String]] {
            #expect(!PaidTests.isCI(notCI), "\(notCI)")
        }
        #expect(PaidTests.value(key, in: ["CI": "false", key: "sk-123"]) == "sk-123")
    }
}
