import AppKit
import Foundation

/// Benchmarks only (`@_spi(Benchmarks) import Penumbra`): typesets one logical line the way a line
/// controller does, without a view, so a harness can time the typesetter on long tokens (F11).
@_spi(Benchmarks)
public enum LineTypesetterBenchmark {
    public struct Result: Sendable {
        public var fragments: Int
        public var createdLines: Int
        public var seconds: Double
    }

    public static func typeset(_ text: String, width: CGFloat, wrapsCharacters: Bool = false) -> Result {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let string = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = LineTypesetter(lineID: "benchmark")
        typesetter.lineBreakMode = wrapsCharacters ? .byCharWrapping : .byWordWrapping
        typesetter.constrainingWidth = width
        typesetter.reset()
        typesetter.prepareToTypeset(string)
        let start = DispatchTime.now().uptimeNanoseconds
        let fragments = typesetter.typesetLineFragments(toLocation: string.length)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
        return Result(fragments: fragments.count, createdLines: typesetter.createdLineCount, seconds: seconds)
    }
}
