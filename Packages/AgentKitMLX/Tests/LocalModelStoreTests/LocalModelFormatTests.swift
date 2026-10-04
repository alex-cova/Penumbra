import Foundation
import Testing
@testable import LocalModelStore

struct LocalModelFormatTests {
    @Test func parametersUseBillionsAndMillions() {
        #expect(LocalModelFormat.parameters(4_022_468_096) == "4.0B")
        #expect(LocalModelFormat.parameters(27_781_427_952) == "27.8B")
        #expect(LocalModelFormat.parameters(135_000_000) == "135M")
        #expect(LocalModelFormat.parameters(999) == "999")
    }

    @Test func compactCountAbbreviatesThousands() {
        #expect(LocalModelFormat.compactCount(0) == "0")
        #expect(LocalModelFormat.compactCount(950) == "950")
        #expect(LocalModelFormat.compactCount(19_750).contains("K"))
    }

    @Test func nameHelpersSplitTheRepositoryID() {
        #expect(LocalModelFormat.shortName("mlx-community/Qwen3-4B-4bit") == "Qwen3-4B-4bit")
        #expect(LocalModelFormat.owner("mlx-community/Qwen3-4B-4bit") == "mlx-community")
    }

    @Test func nameHelpersToleratedMalformedIDs() {
        #expect(LocalModelFormat.shortName("noslash") == "noslash")
        #expect(LocalModelFormat.shortName("") == "")
        #expect(LocalModelFormat.owner("") == "")
    }

    @Test func elapsedReadsAsSecondsThenMinutes() {
        #expect(LocalModelFormat.elapsed(0) == "<1s")
        #expect(LocalModelFormat.elapsed(0.4) == "<1s")
        #expect(LocalModelFormat.elapsed(4.2) == "4s")
        #expect(LocalModelFormat.elapsed(59.4) == "59s")
        #expect(LocalModelFormat.elapsed(65) == "1m 5s")
        #expect(LocalModelFormat.elapsed(120) == "2m 0s")
    }

    @Test func bytesReadAsFileSizes() {
        #expect(LocalModelFormat.bytes(0).contains("0") || LocalModelFormat.bytes(0).contains("Zero"))
        #expect(LocalModelFormat.bytes(2_263_022_529).contains("GB"))
    }
}
