import LocalModelStore
import XCTest
@testable import Umbra

final class IDELocalModelFilterTests: XCTestCase {
    func testTheSizeComesFromTheName() {
        XCTAssertEqual(IDELocalModelFilter.billions(inName: "mlx-community/Qwen3-4B-4bit"), 4)
        XCTAssertEqual(IDELocalModelFilter.billions(inName: "mlx-community/Qwen3-1.7B-4bit"), 1.7)
        XCTAssertEqual(IDELocalModelFilter.billions(inName: "prism-ml/Bonsai-27B-mlx-1bit"), 27)
        XCTAssertEqual(IDELocalModelFilter.billions(inName: "mlx-community/Mixtral-8x7B-Instruct-4bit"), 56)
        XCTAssertEqual(IDELocalModelFilter.billions(inName: "x/SmolLM2-135M-Instruct")!, 0.135, accuracy: 0.0001)
        XCTAssertEqual(IDELocalModelFilter.billions(inName: "mlx-community/Qwen3-30B-A3B-4bit"), 30, "the active-expert size is not the model's")
        XCTAssertNil(IDELocalModelFilter.billions(inName: "mlx-community/Llama-3.2-Instruct"), "3.2 is a version, not a size")
    }

    func testThePrecisionComesFromTheTagThenTheName() {
        XCTAssertEqual(IDELocalModelFilter.bits(of: HFModelSummary(id: "a/b", tags: ["mlx", "8-bit"])), 8)
        XCTAssertEqual(IDELocalModelFilter.bits(of: HFModelSummary(id: "mlx-community/Qwen3-4B-4bit")), 4)
        XCTAssertEqual(IDELocalModelFilter.bits(of: HFModelSummary(id: "prism-ml/Bonsai-27B-mlx-1bit")), 1)
        XCTAssertNil(IDELocalModelFilter.bits(of: HFModelSummary(id: "mlx-community/Qwen3-0.6B-Base-DQ5")))
    }

    func testAPackedSafetensorsTotalIsNotTakenForTheSizeOfAQuantizedModel() {
        let packed = HFModelSummary(id: "a/mystery-4bit", tags: ["4-bit"], parameterCount: 600_000_000)
        XCTAssertNil(IDELocalModelFilter.billions(of: packed))
        let full = HFModelSummary(id: "a/mystery", parameterCount: 3_000_000_000)
        XCTAssertEqual(IDELocalModelFilter.billions(of: full), 3)
    }

    func testFiltersCombineAndUnknownsAreHidden() {
        var filter = IDELocalModelFilter()
        XCTAssertTrue(filter.matches(bits: nil, billions: nil), "no filter shows everything")

        filter.precision = .fourBit
        XCTAssertTrue(filter.matches(bits: 4, billions: nil))
        XCTAssertFalse(filter.matches(bits: 8, billions: 4))
        XCTAssertFalse(filter.matches(bits: nil, billions: 4))

        filter.parameters = .from2to5
        XCTAssertTrue(filter.matches(bits: 4, billions: 4))
        XCTAssertFalse(filter.matches(bits: 4, billions: 8))
        XCTAssertFalse(filter.matches(bits: 4, billions: nil))

        filter.precision = .full
        XCTAssertTrue(filter.matches(bits: nil, billions: 2))
        XCTAssertFalse(filter.matches(bits: 4, billions: 2))
    }

    func testTheRangesMeetWithoutGapsOrOverlap() {
        for billions in [0.5, 1.99, 2, 4.99, 5, 9.99, 10, 29.99, 30, 70] {
            XCTAssertEqual(IDELocalModelFilter.Parameters.allCases.filter { $0.contains(billions) }.count, 1, "\(billions)")
        }
    }

    func testOneBitHasNoFilterOptionBecauseMLXCannotRunIt() {
        XCTAssertFalse(IDELocalModelFilter.Precision.allCases.contains { $0.bits == 1 })
    }

    func testTheSuggestionsCanBeFiltered() {
        var filter = IDELocalModelFilter()
        filter.precision = .fourBit
        let fourBit = IDESuggestedLocalModels.all.filter(filter.matches)
        XCTAssertEqual(fourBit.count, IDESuggestedLocalModels.all.count, "every suggestion is 4-bit")
        filter = IDELocalModelFilter()
        filter.parameters = .under2
        XCTAssertTrue(IDESuggestedLocalModels.all.filter(filter.matches).allSatisfy { $0.parameterBillions < 2 })
    }

    func testTheSuggestionsAgreeWithTheirNames() {
        for model in IDESuggestedLocalModels.all {
            XCTAssertEqual(IDELocalModelFilter.bits(inName: model.id), model.bits, model.id)
            if let named = IDELocalModelFilter.billions(inName: model.id) {
                XCTAssertEqual(named, model.parameterBillions, accuracy: 0.0001, model.id)
            }
        }
    }

    func testSizeLabels() {
        XCTAssertEqual(IDELocalModelFilter.sizeLabel(billions: 27), "27B")
        XCTAssertEqual(IDELocalModelFilter.sizeLabel(billions: 1.7), "1.7B")
        XCTAssertEqual(IDELocalModelFilter.sizeLabel(billions: 0.135), "135M")
    }
}
