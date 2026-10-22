import Testing
@testable import AgentKitMLX

@Suite struct MLXGenerationSettingsTests {
    @Test func samplingCarriesARepetitionPenalty() {
        let parameters = MLXGenerationSettings().generateParameters()
        #expect(parameters.temperature == 0.2)
        #expect(parameters.topP == 0.95)
        #expect(parameters.maxTokens == 8_192)
        #expect(parameters.repetitionPenalty == 1.1)
        #expect(parameters.repetitionContextSize == 64)
    }
}
