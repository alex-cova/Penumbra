import Foundation
@_spi(Benchmarks) import JavaIntelligence

/// Release-mode cost of getting a Java file's stubs after an edit: moved from the previous ones
/// (`JavaStubReuse`) against the full rebuild, at several file sizes, for an edit inside a method
/// body and for a structural edit (a renamed method), which must rebuild.
///
///   swift run -c release PerfHarness java-stub-reuse synthetic [--samples N]
///
/// `UMBRA_JAVA_STUB_REUSE=0` turns reuse off, which gives the "before" for the typing request.
enum JavaStubReuseProfile {
    /// Lines per size; each method is five lines.
    private static let sizes = [5_000, 20_000, 120_000]

    static func run(samples: Int) {
        print("=== java stub reuse (samples=\(samples)) ===")
        for lines in sizes {
            let methods = lines / 5
            let source = bigClass(methods: methods)
            guard let bench = JavaStubReuseBenchmark(source: source) else { print("parse failed"); continue }
            let middle = methods / 2
            let anchor = "return d + \(middle);"
            print("size lines=\(lines) methods=\(methods) classes=\(bench.classCount)")

            // Typing inside a method body, one character at a time.
            var bodyParse: [Double] = [], bodyStubs: [Double] = [], bodyRebuild: [Double] = []
            var reused = 0, matches = 0, steps = 0
            for step in 0..<(samples + 2) {
                let typed = String(repeating: "x", count: step + 1)
                let text = source.replacingOccurrences(of: anchor, with: anchor + " int " + typed + " = 1;")
                guard let outcome = bench.advance(to: text) else { continue }
                guard step >= 2 else { continue }  // warm-up
                bodyParse.append(outcome.parseSeconds); bodyStubs.append(outcome.stubSeconds); bodyRebuild.append(outcome.fullRebuildSeconds)
                steps += 1
                if outcome.reused { reused += 1 }
                if outcome.matchesFullRebuild { matches += 1 }
            }
            report("body_edit", parse: bodyParse, stubs: bodyStubs, rebuild: bodyRebuild, reused: reused, matches: matches, steps: steps)

            // Structural: rename a method each step. The stubs must be rebuilt.
            var structParse: [Double] = [], structStubs: [Double] = [], structRebuild: [Double] = []
            reused = 0; matches = 0; steps = 0
            for step in 0..<(samples + 2) {
                let text = source.replacingOccurrences(of: "int method\(middle)(", with: "int method\(middle)\(String(repeating: "y", count: step + 1))(")
                guard let outcome = bench.advance(to: text) else { continue }
                guard step >= 2 else { continue }
                structParse.append(outcome.parseSeconds); structStubs.append(outcome.stubSeconds); structRebuild.append(outcome.fullRebuildSeconds)
                steps += 1
                if outcome.reused { reused += 1 }
                if outcome.matchesFullRebuild { matches += 1 }
            }
            report("structural_edit", parse: structParse, stubs: structStubs, rebuild: structRebuild, reused: reused, matches: matches, steps: steps)
        }

        // Heap held by a run of successive stub sets (50 keystrokes), moved against rebuilt.
        let source = bigClass(methods: 4_000)
        let anchor = "return d + 2000;"
        let edit: (Int) -> String = { source.replacingOccurrences(of: anchor, with: anchor + " int " + String(repeating: "x", count: $0) + " = 1;") }
        let moved = JavaStubReuseBenchmark.retainedBytes(source: source, edit: edit, generations: 50, allowReuse: true)
        let rebuilt = JavaStubReuseBenchmark.retainedBytes(source: source, edit: edit, generations: 50, allowReuse: false)
        print("memory generations=50 lines=20000 reuse_bytes=\(moved) rebuild_bytes=\(rebuilt) reuse_per_generation=\(moved / 50) rebuild_per_generation=\(rebuilt / 50)")
        let counts = JavaStubReuseStatistics.counts
        print("invalidation reused=\(counts.reused) rebuilt=\(counts.rebuilt)")
    }

    private static func report(_ kind: String, parse: [Double], stubs: [Double], rebuild: [Double], reused: Int, matches: Int, steps: Int) {
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        guard steps > 0 else { return }
        print(String(
            format: "  %@ reused=%d/%d equals_full_rebuild=%d/%d parse_ms=%.3f stubs_ms=%.3f full_rebuild_ms=%.3f",
            kind, reused, steps, matches, steps, median(parse) * 1000, median(stubs) * 1000, median(rebuild) * 1000
        ))
    }

    private static func bigClass(methods: Int) -> String {
        var text = "package big;\nimport java.util.*;\npublic class Big {\n    int field;\n"
        for index in 0..<methods {
            text += "    /** m\(index) */\n    public int method\(index)(int a, String b) {\n        int d = a * 2;\n        return d + \(index);\n    }\n"
        }
        return text + "    static class Tail { void t() { } }\n}\n"
    }
}
