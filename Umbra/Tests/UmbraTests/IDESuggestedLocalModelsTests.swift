import AgentKitMLX
import XCTest
@testable import Umbra

final class IDESuggestedLocalModelsTests: XCTestCase {
    func testTheSuggestionsAreDistinctRepositoryIDs() {
        let ids = IDESuggestedLocalModels.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.split(separator: "/").count == 2 })
    }

    func testNoSuggestionUsesAQuantizationMLXCannotRun() {
        for model in IDESuggestedLocalModels.all {
            XCTAssertTrue(
                MLXModelInspector.supportedQuantizationBits.contains(model.bits),
                "\(model.id) is suggested but MLX cannot run \(model.bits)-bit weights")
        }
    }

    func testTheSetupSheetOffersAModelThatCanUseTools() {
        XCTAssertEqual(IDESuggestedLocalModels.recommendedForChat.purpose, .agent)
    }

    func testCodeCompletionsModelIsListedSoItCanBeDownloadedInOneClick() {
        XCTAssertTrue(IDESuggestedLocalModels.all.contains { $0.id == IDEInlineCompletionService.recommendedModelID && $0.purpose == .completion })
    }

    func testAModelFitsWhenTheMacHasItsMemory() {
        let model = IDESuggestedLocalModel(id: "x/y", blurb: "", approximateBytes: 1, parameterBillions: 1, bits: 4, purpose: .agent, recommendedMemoryGB: 16)
        XCTAssertFalse(model.fitsMemory(8 * 1_073_741_824))
        XCTAssertTrue(model.fitsMemory(16 * 1_073_741_824))
        let small = IDESuggestedLocalModel(id: "x/z", blurb: "", approximateBytes: 1, parameterBillions: 1, bits: 4, purpose: .agent, recommendedMemoryGB: nil)
        XCTAssertTrue(small.fitsMemory(1))
    }
}
