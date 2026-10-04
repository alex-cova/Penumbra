import Testing
@testable import AgentKitMLX

@Suite struct MLXToolCallRecoveryTests {
    private let tools: Set<String> = ["read_file", "grep"]

    @Test func recoversTheDoubledBracesASmallModelActuallyWrote() {
        // Captured from Qwen2.5-3B-Instruct-4bit.
        let raw = "<tool_call>\n{{\"name\": \"read_file\", \"arguments\": {\"limit\": 500, \"path\": \"NOTES.md\"}}}\n</tool_call>"
        #expect(MLXToolCallRecovery.recover(raw, knownTools: tools) == .init(name: "read_file", arguments: #"{"limit":500,"path":"NOTES.md"}"#))
    }

    @Test func recoversCodeFencesAndParametersInPlaceOfArguments() {
        #expect(MLXToolCallRecovery.recover("```json\n{\"name\": \"grep\", \"parameters\": {\"pattern\": \"x\"}}\n```", knownTools: tools)
            == .init(name: "grep", arguments: #"{"pattern":"x"}"#))
        #expect(MLXToolCallRecovery.recover(#"{{{"name":"grep","arguments":{}}}}"#, knownTools: tools)?.arguments == "{}")
    }

    @Test func refusesWhatItWouldHaveToGuess() {
        // An undeclared tool, a missing name, arguments that are not an object, truncated or plain broken JSON.
        #expect(MLXToolCallRecovery.recover(#"{{"name":"delete_everything","arguments":{}}}"#, knownTools: tools) == nil)
        #expect(MLXToolCallRecovery.recover(#"{"arguments":{"a":1}}"#, knownTools: tools) == nil)
        #expect(MLXToolCallRecovery.recover(#"{"name":"grep","arguments":"pattern=x"}"#, knownTools: tools) == nil)
        #expect(MLXToolCallRecovery.recover(#"{"name":"grep","arguments":{"pattern":"#, knownTools: tools) == nil)
        #expect(MLXToolCallRecovery.recover("I will now read the file", knownTools: tools) == nil)
        #expect(MLXToolCallRecovery.recover("", knownTools: tools) == nil)
    }

    @Test func aWellFormedCallPassesThroughUnchanged() {
        #expect(MLXToolCallRecovery.recover(#"{"name":"read_file","arguments":{"path":"A"}}"#, knownTools: tools)
            == .init(name: "read_file", arguments: #"{"path":"A"}"#))
    }
}
