import Foundation
@_spi(Benchmarks) import JavaIntelligence

/// Where the incremental reparse of a Java file spends its time, piece by piece, at three file
/// sizes and for three kinds of edit: one typed character in the middle of the file, a multi-line
/// block inserted, and a whole method deleted.
///
///   swift run -c release PerfHarness java-parse-edit synthetic [--samples N]
enum JavaParseEditProfile {
    private static let sizes = [5_000, 20_000, 120_000]

    static func run(samples: Int, perClass: Int = 0) {
        print("=== java parse edit (samples=\(samples), \(perClass == 0 ? "one class holds every method" : "\(perClass) methods per nested class")) ===")
        for lines in sizes {
            let methods = lines / 5
            var pieces = Pieces(methods: methods)
            pieces.perClass = perClass
            let middle = methods / 2
            let base = pieces.text()
            print("size lines=\(lines) bytes=\(base.utf8.count)")
            // Each scenario is a sequence of texts; step n is one edit away from step n-1.
            let scenarios: [(String, (Int) -> String)] = [
                ("type_char_middle", { pieces.text(typedAfter: middle, count: $0 + 1) }),
                ("multiline_insert", { pieces.text(blocksAfter: middle, count: $0 + 1) }),
                ("delete_method", { pieces.text(deletingMethods: (middle - $0 - 1)...middle) }),
                ("type_char_start", { pieces.text(packageSuffix: $0 + 1) }),
                ("type_char_end", { pieces.text(tailSuffix: $0 + 1) })
            ]
            for (name, textAt) in scenarios {
                guard let bench = JavaParseEditBenchmark(source: base) else { print("parse failed"); continue }
                var rows: [JavaParseEditBenchmark.Timings] = []
                for step in 0..<(samples + 2) {
                    guard let timings = bench.advance(to: textAt(step)) else { continue }
                    if step >= 2 { rows.append(timings) }  // warm-up
                }
                guard !rows.isEmpty else { print("  \(name): no edit"); continue }
                func median(_ key: KeyPath<JavaParseEditBenchmark.Timings, Double>) -> Double {
                    rows.map { $0[keyPath: key] }.sorted()[rows.count / 2] * 1000
                }
                let ok = rows.allSatisfy(\.matchesReference)
                print(String(
                    format: "  %@ to_bytes=%.3f diff=%.3f [prefix=%.3f suffix=%.3f newlines=%.3f] reference_diff=%.3f copy_apply=%.3f incremental_parse=%.3f total=%.3f edit_bytes=%d..%d->%d matches_reference=%@",
                    name, median(\.toBytes), median(\.diff), median(\.prefixScan), median(\.suffixScan), median(\.newlineScan), median(\.referenceDiff), median(\.copyApply),
                    median(\.incrementalParse), median(\.total),
                    rows[0].edit.start, rows[0].edit.oldEnd, rows[0].edit.newEnd, ok ? "yes" : "NO"
                ))
            }
        }
    }

    /// The generated file as separate parts, so a scenario can edit one spot without a text search.
    private struct Pieces {
        let methods: Int
        /// Members per nested class; 0 puts every method in the one outer class body.
        var perClass = 0
        private let head = "package big;\nimport java.util.*;\npublic class Big {\n    int field;\n"
        private let tail = "    static class Tail { void t() { } }\n}\n"

        init(methods: Int) { self.methods = methods }

        private func method(_ index: Int, extra: String = "") -> String {
            "    /** m\(index) */\n    public int method\(index)(int a, String b) {\n        int d = a * 2;\n        return d + \(index);\(extra)\n    }\n"
        }

        private func assemble(package: String = "big", skipping: ClosedRange<Int>? = nil, extraAt: (Int, String)? = nil, tail tailText: String? = nil) -> String {
            var text = head.replacingOccurrences(of: "package big;", with: "package \(package);")
            for index in 0..<methods {
                if perClass > 0, index % perClass == 0 { text += "    public static class Part\(index / perClass) {\n" }
                if skipping?.contains(index) != true {
                    text += method(index, extra: extraAt.flatMap { $0.0 == index ? $0.1 : nil } ?? "")
                }
                if perClass > 0, index % perClass == perClass - 1 || index == methods - 1 { text += "    }\n" }
            }
            return text + (tailText ?? tail)
        }

        func text() -> String { assemble() }
        func text(typedAfter index: Int, count: Int) -> String { assemble(extraAt: (index, " " + String(repeating: "x", count: count))) }
        func text(blocksAfter index: Int, count: Int) -> String {
            assemble(extraAt: (index, "\n" + String(repeating: "        int extra = 1;\n", count: 12 * count)))
        }
        func text(deletingMethods range: ClosedRange<Int>) -> String { assemble(skipping: range) }
        func text(packageSuffix count: Int) -> String { assemble(package: "big" + String(repeating: "x", count: count)) }
        func text(tailSuffix count: Int) -> String {
            assemble(tail: "    static class Tail { void t() { } }" + String(repeating: " ", count: count) + "\n}\n")
        }
    }
}
