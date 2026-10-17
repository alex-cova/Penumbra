import Foundation
import JavaIntelligence

/// Release-mode cost of building one `JavaScopeTree` (JLS 6.3 scopes for a parse): the parse
/// itself is timed separately, then fresh trees are built per sample so the per-parse
/// attachment cache cannot hide the build cost. Compare against the Phase 3 exit (build at or
/// under 50 ms on a 2k-line file).
///
///   swift run -c release PerfHarness java-scope-tree synthetic [--lines N] [--samples N]
///   swift run -c release PerfHarness java-scope-tree /path/to/Big.java
///
enum JavaScopeTreeProfile {
    static func run(pathOrSynthetic: String, lines: Int, samples: Int) throws {
        let isSynthetic = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-"
        let source = isSynthetic
            ? syntheticJava(lines: lines)
            : String(decoding: try Data(contentsOf: URL(fileURLWithPath: pathOrSynthetic)), as: UTF8.self)
        let lineCount = source.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
        guard let tree = JavaSyntaxParser().parse(source) else {
            throw ScopeTreeProfileFailure(message: "could not parse source")
        }
        let parseStart = DispatchTime.now().uptimeNanoseconds
        guard JavaSyntaxParser().parse(source) != nil else {
            throw ScopeTreeProfileFailure(message: "could not parse source")
        }
        let parse = Double(DispatchTime.now().uptimeNanoseconds - parseStart) / 1e9
        let url = URL(fileURLWithPath: "/proj/ScopeTreePerf.java")
        var builds: [Double] = []
        for _ in 0 ..< samples {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = JavaScopeTree(tree: tree, url: url)
            builds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        let sorted = builds.sorted()
        let median = sorted[sorted.count / 2]
        print("stage java_scope_tree lines=\(lineCount) count=\(sorted.count) parse_s=\(format(parse)) build_median_s=\(format(median)) build_worst_s=\(format(sorted.last ?? 0))")
    }

    /// Flat methods with locals, branches and patterns, so the tree builds scopes instead of
    /// only counting members.
    static func syntheticJava(lines target: Int) -> String {
        var out = ["class ScopePerf {"]
        var index = 0
        while out.count < target {
            out.append("    int field\(index) = \(index);")
            out.append("    String name\(index)(Object input, int limit) {")
            out.append("        int total = field\(index) + limit;")
            out.append("        if (input instanceof String text && text.length() > total) {")
            out.append("            total += text.length();")
            out.append("        } else {")
            out.append("            total -= 1;")
            out.append("        }")
            out.append("        for (int i = 0; i < limit; i++) { total += i; }")
            out.append("        return String.valueOf(total);")
            out.append("    }")
            index += 1
        }
        out.append("}")
        return out.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String { String(format: "%.6f", value) }
}

private struct ScopeTreeProfileFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
