import Foundation
@_spi(Benchmarks) import Penumbra

/// F11: how long does the line typesetter take on long unbreakable tokens and runs of spaces?
///
///   swift run -c release PerfHarness typeset-long synthetic [--samples N]
enum TypesetProfile {
    static func run(samples: Int) {
        let cases: [(String, String, CGFloat)] = [
            ("10k unbreakable token, width 800", String(repeating: "abcdefghij", count: 1000), 800),
            ("base64 20k, width 800", String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=", count: 560), 800),
            ("minified js 50k, width 800", String(repeating: "function(a,b){return a+b;};", count: 1850), 800),
            ("50k code line, width 10000", String(repeating: "let value = compute(a, b, c) + fallback(); ", count: 1150), 10_000),
            ("2,000 spaces then a word, width 800", String(repeating: " ", count: 2000) + "tail text here", 800),
            ("20,000 spaces then a word, width 800", String(repeating: " ", count: 20_000) + "tail text here", 800),
            ("20 words, 300 spaces between, width 800", (0 ..< 20).map { _ in "word" + String(repeating: " ", count: 300) }.joined(), 800)
        ]
        for (label, text, width) in cases {
            var seconds: [Double] = []
            var last = LineTypesetterBenchmark.typeset(text, width: width)
            for _ in 0 ..< max(samples, 1) {
                last = LineTypesetterBenchmark.typeset(text, width: width)
                seconds.append(last.seconds)
            }
            seconds.sort()
            let median = seconds[seconds.count / 2]
            let line = String(
                format: "  %-42@ fragments=%-5d lines built=%-6d median=%8.3f ms",
                label as NSString, last.fragments, last.createdLines, median * 1000
            )
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        }
    }
}
