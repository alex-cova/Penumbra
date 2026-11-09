import Foundation

/// Drives ``JavaStubReuse`` for `PerfHarness java-stub-reuse`: one file edited step by step, with
/// the cost of the step split into parse and stubs, the full rebuild of the same tree for
/// comparison, and a check that the two agree.
@_spi(Benchmarks)
public final class JavaStubReuseBenchmark {
    public struct Step {
        public let reused: Bool
        /// Incremental parse, in seconds.
        public let parseSeconds: Double
        /// Stubs for the new tree: moved from the previous ones, or rebuilt.
        public let stubSeconds: Double
        /// `JavaSourceStubBuilder.build(tree:)` on the same tree, for comparison.
        public let fullRebuildSeconds: Double
        public let matchesFullRebuild: Bool
    }

    private let url: URL
    private let parser = JavaSyntaxParser()
    private var tree: JavaSyntaxTree
    private var stubs: JavaSourceFileStubs

    public init?(source: String, url: URL = URL(fileURLWithPath: "/virtual/Bench.java")) {
        guard let tree = parser.parse(source) else { return nil }
        self.url = url
        self.tree = tree
        self.stubs = JavaSourceStubBuilder.build(tree: tree, url: url)
    }

    public var classCount: Int { stubs.classes.count }

    public func advance(to text: String) -> Step? {
        JavaCompletionStageTimer.enable(true)
        JavaCompletionStageTimer.reset()
        let before = JavaStubReuseStatistics.counts
        guard let result = JavaStubReuse.reparse(previous: (tree, stubs), to: text, parser: parser, url: url) else {
            JavaCompletionStageTimer.enable(false)
            return nil
        }
        let stages = JavaCompletionStageTimer.snapshot()
        JavaCompletionStageTimer.enable(false)
        let reused = JavaStubReuseStatistics.counts.reused > before.reused

        let start = DispatchTime.now().uptimeNanoseconds
        let rebuilt = JavaSourceStubBuilder.build(tree: result.tree, url: url)
        let rebuildSeconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
        let matches = rebuilt.classes == result.stubs.classes && rebuilt.imports == result.stubs.imports
            && rebuilt.packageName == result.stubs.packageName

        tree = result.tree
        stubs = result.stubs
        return Step(
            reused: reused, parseSeconds: stages["parse"] ?? 0, stubSeconds: stages["stubs"] ?? 0,
            fullRebuildSeconds: rebuildSeconds, matchesFullRebuild: matches
        )
    }

    /// Heap held by `generations` successive stub sets, each made from the previous by one edit:
    /// moved when `allowReuse`, else rebuilt. Only the stubs are kept; the trees are let go.
    public static func retainedBytes(source: String, edit: (Int) -> String, generations: Int, allowReuse: Bool) -> Int {
        let parser = JavaSyntaxParser()
        let url = URL(fileURLWithPath: "/virtual/Bench.java")
        guard var tree = parser.parse(source) else { return 0 }
        var stubs = JavaSourceStubBuilder.build(tree: tree, url: url)
        var kept: [JavaSourceFileStubs] = []
        kept.reserveCapacity(generations)
        let before = heapInUse()
        for generation in 1...generations {
            let text = edit(generation)
            if allowReuse {
                guard let result = JavaStubReuse.reparse(previous: (tree, stubs), to: text, parser: parser, url: url) else { return 0 }
                tree = result.tree
                stubs = result.stubs
            } else {
                guard let next = parser.parse(text) else { return 0 }
                tree = next
                stubs = JavaSourceStubBuilder.build(tree: next, url: url)
            }
            kept.append(stubs)
        }
        let after = heapInUse()
        withExtendedLifetime(kept) {}
        return after - before
    }

    private static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }
}
