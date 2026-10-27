import Foundation
import SwiftIntelligence

/// Release-mode cost of what swift-syntax adds to `SwiftIntelligence` (Phase 3 of
/// `docs/SWIFT_INTELLIGENCE_ROADMAP.md`), next to what the editor does with tree-sitter today:
///
/// - `ts_*`: `SwiftAnalysis.parseModel`, tree-sitter's parse plus the `SwiftFileModel` walk (the memo is bypassed). The editor
///   pays this on the paths that follow typing.
/// - `syntax_parse_*`: `SwiftSyntaxDocument.parse`, swift-syntax's parse. Not incremental.
/// - `syntax_scopes_*`: `SwiftSyntaxScopes.references`, the scope lookup of every identifier reference
///   on an already-parsed tree.
///
/// The result decides where swift-syntax may run: a pause in typing, a save or a run of inspections can
/// afford what a keystroke cannot. The budget below is the gate for the former.
///
///   swift run -c release PerfHarness swift-syntax-parse synthetic [--lines N] [--samples N]
///   swift run -c release PerfHarness swift-syntax-parse /path/to/Big.swift
///
enum SwiftSyntaxProfile {
    /// Parse and scope lookup of a 2,000-line file, in seconds, release build. Over this the harness
    /// exits non-zero. Work that runs after a pause (an inspection pass, a quick fix) stays under it.
    static let budgetSeconds = 0.075

    static func run(pathOrSynthetic: String, lines: Int, samples: Int) throws {
        let isSynthetic = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-"
        let source = isSynthetic
            ? syntheticSwift(lines: lines)
            : String(decoding: try Data(contentsOf: URL(fileURLWithPath: pathOrSynthetic)), as: UTF8.self)
        let lineCount = source.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }

        guard SwiftAnalysis.parse(source) != nil else { throw SwiftSyntaxProfileFailure(message: "tree-sitter could not parse the source") }
        let document = SwiftSyntaxDocument.parse(source)
        let referenceCount = SwiftSyntaxScopes.references(in: document).count

        // `SwiftAnalysis.parse` memoizes by text, so a repeated call measures the dictionary. A different
        // trailing comment per sample makes each one a real parse and model walk.
        var variant = 0
        let treeSitter = time(samples) {
            variant += 1
            _ = SwiftAnalysis.parseModel(source + "\n// sample \(variant)")
        }
        let syntaxParse = time(samples) { _ = SwiftSyntaxDocument.parse(source) }
        let syntaxScopes = time(samples) { _ = SwiftSyntaxScopes.references(in: document) }
        let cache = SwiftSyntaxParseCache(capacity: 2)
        _ = cache.document(for: source)
        let cached = time(samples) { _ = cache.document(for: source) }

        func f(_ value: Double) -> String { String(format: "%.6f", value) }
        print("""
        stage swift_syntax lines=\(lineCount) bytes=\(source.utf8.count) references=\(referenceCount) count=\(samples) \
        ts_median_s=\(f(treeSitter.median)) ts_worst_s=\(f(treeSitter.worst)) \
        syntax_parse_median_s=\(f(syntaxParse.median)) syntax_parse_worst_s=\(f(syntaxParse.worst)) \
        syntax_scopes_median_s=\(f(syntaxScopes.median)) syntax_scopes_worst_s=\(f(syntaxScopes.worst)) \
        cache_hit_median_s=\(f(cached.median))
        """)
        let total = syntaxParse.median + syntaxScopes.median
        print("syntax_total_median_s=\(f(total)) budget_s=\(f(budgetSeconds)) (a 2,000-line file; scale lines for others)")
        if isSynthetic, lineCount >= 1_800, lineCount <= 2_200, total > budgetSeconds {
            throw SwiftSyntaxProfileFailure(message: "parse + scopes took \(f(total)) s, over the \(f(budgetSeconds)) s budget")
        }
    }

    private static func time(_ samples: Int, _ work: () -> Void) -> (median: Double, worst: Double) {
        var durations: [Double] = []
        for _ in 0 ..< max(samples, 1) {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        let sorted = durations.sorted()
        return (sorted[sorted.count / 2], sorted.last ?? 0)
    }

    /// Methods with parameters, optional bindings, loops and closures, so the lookup has scopes to walk.
    static func syntheticSwift(lines target: Int) -> String {
        var out = ["struct ScopePerf {"]
        var index = 0
        while out.count < target {
            out.append("    var field\(index) = \(index)")
            out.append("    func name\(index)(input: Any?, limit: Int) -> String {")
            out.append("        var total = field\(index) + limit")
            out.append("        if let text = input as? String, text.count > total {")
            out.append("            total += text.count")
            out.append("        } else {")
            out.append("            total -= 1")
            out.append("        }")
            out.append("        for i in 0..<limit { total += i }")
            out.append("        let doubled = (0..<limit).map { value in value * 2 }")
            out.append("        return String(total + doubled.count)")
            out.append("    }")
            index += 1
        }
        out.append("}")
        return out.joined(separator: "\n")
    }
}

private struct SwiftSyntaxProfileFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
