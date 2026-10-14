import Foundation

/// Two profiles of the same kind, side by side: a merged call tree to draw as a differential flame
/// graph, and a per-method table with both numbers.
///
/// The recordings have symbol tables of their own, so frames are matched by method (class, name,
/// parameters) and not by line: lines move between two versions of the code, which is what is being
/// compared. Counts are compared as shares of each profile's total unless asked for absolutely, so
/// a run twice as long is not twice as slow everywhere.
public struct JavaProfileComparison: Sendable {
    public enum Basis: Sendable {
        /// Each profile's counts as a fraction of its own total.
        case share
        /// The sample counts as recorded.
        case absolute
    }

    public struct MethodRow: Equatable, Identifiable, Sendable {
        public var method: JavaProfileSymbols.Method
        public var baselineSelf: Int
        public var baselineTotal: Int
        public var targetSelf: Int
        public var targetTotal: Int

        public var id: JavaProfileSymbols.Method { method }
    }

    public let basis: Basis
    public let baselineSamples: Int
    public let targetSamples: Int
    /// Methods of either profile, the biggest change in self share first.
    public let rows: [MethodRow]
    /// The merged tree: a node's width is the larger of its two sides, so the children of a node
    /// always fit under it. Its frames are line-less.
    public let tree: JavaProfileTree
    public let symbols: JavaProfileSymbols
    /// Samples at each node of ``tree`` in the baseline and in the target.
    public let baselineCounts: [Int]
    public let targetCounts: [Int]

    /// Parts per million of a profile's total that one sample of weight 1 gets in a merged tree.
    private static let scale = 1_000_000.0

    public static func compare(
        baseline: JavaProfileTree, baselineSymbols: JavaProfileSymbols,
        target: JavaProfileTree, targetSymbols: JavaProfileSymbols,
        basis: Basis = .share
    ) -> JavaProfileComparison {
        let merger = Merger(baseline: baseline, baselineSymbols: baselineSymbols, target: target, targetSymbols: targetSymbols)
        merger.run()

        let baseTotal = max(baseline.totalSamples, 0)
        let targetTotal = max(target.totalSamples, 0)

        // Width in the merged tree: the larger side's self weight, in shares or in samples.
        func weight(base: Int, target: Int) -> Int {
            switch basis {
            case .absolute:
                return max(base, target)
            case .share:
                let b = baseTotal > 0 ? Double(base) / Double(baseTotal) : 0
                let t = targetTotal > 0 ? Double(target) / Double(targetTotal) : 0
                let width = Int((max(b, t) * scale).rounded())
                return (base > 0 || target > 0) ? max(width, 1) : 0
            }
        }

        let symbols = JavaProfileSymbols()
        var frameOfKey: [Int32: Int32] = [:]
        func frame(forKey key: Int32) -> Int32 {
            if key == Merger.otherKey { return JavaProfileTree.otherFrame }
            if let known = frameOfKey[key] { return known }
            let method = merger.methods[Int(key)]
            let id = symbols.internFrame(
                method: symbols.internMethod(className: method.className, name: method.name, parameters: method.parameters),
                line: 0
            )
            frameOfKey[key] = id
            return id
        }

        var tree = JavaProfileTree(nodeLimit: max(baseline.nodeLimit, target.nodeLimit))
        var stack: [(node: Int, frames: [Int32])] = [(0, [])]
        while let (node, path) = stack.popLast() {
            let own = weight(base: merger.baselineSelf[node], target: merger.targetSelf[node])
            if own > 0 { tree.add(stack: path, weight: own) }
            for child in merger.children[node] {
                stack.append((child, path + [frame(forKey: merger.keys[child])]))
            }
        }

        // The merged tree's own nodes, lined up with the comparison's: same shape, children by key.
        var baselineCounts = [Int](repeating: 0, count: tree.nodeCount)
        var targetCounts = [Int](repeating: 0, count: tree.nodeCount)
        var keyOfFrame: [Int32: Int32] = [JavaProfileTree.otherFrame: Merger.otherKey]
        for (key, frame) in frameOfKey { keyOfFrame[frame] = key }
        var pairs: [(flame: Int, merged: Int)] = [(JavaProfileTree.root, 0)]
        while let (flame, merged) = pairs.popLast() {
            baselineCounts[flame] = merger.baselineTotal[merged]
            targetCounts[flame] = merger.targetTotal[merged]
            var byKey: [Int32: Int] = [:]
            for child in merger.children[merged] { byKey[merger.keys[child]] = child }
            for child in tree.children(of: flame) {
                if let key = keyOfFrame[tree.frame(of: child)], let mergedChild = byKey[key] {
                    pairs.append((child, mergedChild))
                }
            }
        }

        // The method table: each profile's own hot methods, joined by method.
        var rows: [JavaProfileSymbols.Method: MethodRow] = [:]
        for hot in baseline.hotMethods(symbols: baselineSymbols) {
            let method = baselineSymbols.methods[Int(hot.method)]
            var row = rows[method] ?? MethodRow(method: method, baselineSelf: 0, baselineTotal: 0, targetSelf: 0, targetTotal: 0)
            row.baselineSelf = hot.selfCount
            row.baselineTotal = hot.totalCount
            rows[method] = row
        }
        for hot in target.hotMethods(symbols: targetSymbols) {
            let method = targetSymbols.methods[Int(hot.method)]
            var row = rows[method] ?? MethodRow(method: method, baselineSelf: 0, baselineTotal: 0, targetSelf: 0, targetTotal: 0)
            row.targetSelf = hot.selfCount
            row.targetTotal = hot.totalCount
            rows[method] = row
        }
        func share(_ count: Int, of total: Int) -> Double { total > 0 ? Double(count) / Double(total) : 0 }
        let sorted = rows.values.sorted { lhs, rhs in
            let l = abs(share(lhs.targetSelf, of: targetTotal) - share(lhs.baselineSelf, of: baseTotal))
            let r = abs(share(rhs.targetSelf, of: targetTotal) - share(rhs.baselineSelf, of: baseTotal))
            if l != r { return l > r }
            return (lhs.method.className + lhs.method.name) < (rhs.method.className + rhs.method.name)
        }

        return JavaProfileComparison(
            basis: basis, baselineSamples: baseTotal, targetSamples: targetTotal, rows: sorted,
            tree: tree, symbols: symbols, baselineCounts: baselineCounts, targetCounts: targetCounts
        )
    }

    /// How much a node of ``tree`` changed, from -1 (only in the baseline) through 0 (the same
    /// share) to +1 (only in the target): the difference of its two shares over the larger.
    public func change(ofNode node: Int) -> Double {
        guard node >= 0, node < baselineCounts.count else { return 0 }
        let b = baselineSamples > 0 ? Double(baselineCounts[node]) / Double(baselineSamples) : 0
        let t = targetSamples > 0 ? Double(targetCounts[node]) / Double(targetSamples) : 0
        let larger = max(b, t)
        return larger > 0 ? (t - b) / larger : 0
    }

    /// Share of a profile's samples, 0...1.
    public func baselineShare(ofNode node: Int) -> Double {
        baselineSamples > 0 && node < baselineCounts.count ? Double(baselineCounts[node]) / Double(baselineSamples) : 0
    }

    public func targetShare(ofNode node: Int) -> Double {
        targetSamples > 0 && node < targetCounts.count ? Double(targetCounts[node]) / Double(targetSamples) : 0
    }

    // MARK: - Merging

    /// Walks both trees together, grouping the children of each merged node by method.
    private final class Merger {
        static let otherKey: Int32 = -2

        let baseline: JavaProfileTree
        let baselineSymbols: JavaProfileSymbols
        let target: JavaProfileTree
        let targetSymbols: JavaProfileSymbols

        private(set) var methods: [JavaProfileSymbols.Method] = []
        private var methodIDs: [JavaProfileSymbols.Method: Int32] = [:]

        private(set) var keys: [Int32] = [-1]
        private(set) var children: [[Int]] = [[]]
        private(set) var baselineSelf: [Int] = [0]
        private(set) var targetSelf: [Int] = [0]
        private(set) var baselineTotal: [Int] = [0]
        private(set) var targetTotal: [Int] = [0]

        init(
            baseline: JavaProfileTree, baselineSymbols: JavaProfileSymbols,
            target: JavaProfileTree, targetSymbols: JavaProfileSymbols
        ) {
            self.baseline = baseline
            self.baselineSymbols = baselineSymbols
            self.target = target
            self.targetSymbols = targetSymbols
        }

        private func key(of frame: Int32, in symbols: JavaProfileSymbols) -> Int32 {
            if frame == JavaProfileTree.otherFrame { return Self.otherKey }
            let method = symbols.method(ofFrame: frame)
            if let known = methodIDs[method] { return known }
            let id = Int32(methods.count)
            methods.append(method)
            methodIDs[method] = id
            return id
        }

        func run() {
            baselineSelf[0] = baseline.selfCount(of: JavaProfileTree.root)
            targetSelf[0] = target.selfCount(of: JavaProfileTree.root)
            baselineTotal[0] = baseline.totalCount(of: JavaProfileTree.root)
            targetTotal[0] = target.totalCount(of: JavaProfileTree.root)
            var work: [(merged: Int, baseNodes: [Int], targetNodes: [Int])] = [(0, [JavaProfileTree.root], [JavaProfileTree.root])]
            while let (merged, baseNodes, targetNodes) = work.popLast() {
                var order: [Int32] = []
                var groups: [Int32: (base: [Int], target: [Int])] = [:]
                for node in baseNodes {
                    for child in baseline.children(of: node) {
                        let k = key(of: baseline.frame(of: child), in: baselineSymbols)
                        if groups[k] == nil { order.append(k) }
                        groups[k, default: ([], [])].base.append(child)
                    }
                }
                for node in targetNodes {
                    for child in target.children(of: node) {
                        let k = key(of: target.frame(of: child), in: targetSymbols)
                        if groups[k] == nil { order.append(k) }
                        groups[k, default: ([], [])].target.append(child)
                    }
                }
                for k in order {
                    guard let group = groups[k] else { continue }
                    let index = keys.count
                    keys.append(k)
                    children.append([])
                    children[merged].append(index)
                    baselineSelf.append(group.base.reduce(0) { $0 + baseline.selfCount(of: $1) })
                    targetSelf.append(group.target.reduce(0) { $0 + target.selfCount(of: $1) })
                    baselineTotal.append(group.base.reduce(0) { $0 + baseline.totalCount(of: $1) })
                    targetTotal.append(group.target.reduce(0) { $0 + target.totalCount(of: $1) })
                    work.append((index, group.base, group.target))
                }
            }
        }
    }
}

// MARK: - Whether two recordings can be compared

extension JavaProfileComparison {
    /// What can be said about comparing two recordings for one kind of event and thread, before any
    /// tree is built.
    public enum Compatibility: Equatable, Sendable {
        /// Nothing to say.
        case compatible
        /// The comparison is meaningful, but a number of it needs a caveat.
        case warning(String)
        /// There is nothing to compare: the sentence says why.
        case incompatible(String)

        public var message: String? {
            switch self {
            case .compatible: return nil
            case .warning(let text), .incompatible(let text): return text
            }
        }

        public var isIncompatible: Bool {
            if case .incompatible = self { return true }
            return false
        }
    }

    /// How far two CPU sampling periods may be apart before the sample counts stop being alike.
    /// A 10 ms and a 20 ms recording is a factor 2; the estimate itself can be a millisecond off.
    static let periodRatioLimit = 1.5

    /// Whether `target`'s tree for `kind` and `thread` can be set against `baseline`'s. The thread
    /// is looked up by name in both: a worker pool's `pool-1-thread-3` is not the baseline's, and a
    /// missing one would otherwise read as "everything got cheaper".
    public static func compatibility(
        baseline: JavaProfile, target: JavaProfile, kind: JavaSampleKind, thread: String?, basis: Basis = .share
    ) -> Compatibility {
        let noun: String
        switch kind {
        case .cpu: noun = "CPU"
        case .allocation: noun = "allocation"
        case .contention: noun = "wait"
        }
        let baselineTable = baseline.samples(of: kind)
        let targetTable = target.samples(of: kind)
        if baselineTable.count == 0 {
            return .incompatible("The baseline has no \(noun) samples"
                + (kind == .allocation ? " (Java 16 or newer records them)." : "."))
        }
        if targetTable.count == 0 {
            return .incompatible("This recording has no \(noun) samples to compare.")
        }
        if let thread {
            let inBaseline = baseline.threads(of: kind).contains { $0.name == thread }
            if !inBaseline {
                return .incompatible("The baseline has no \(noun) samples on thread \"\(thread)\". Choose All Threads.")
            }
        }
        if kind == .cpu,
           let baselinePeriod = baseline.estimatedCPUSamplePeriodMilliseconds(),
           let targetPeriod = target.estimatedCPUSamplePeriodMilliseconds(),
           baselinePeriod > 0, targetPeriod > 0 {
            let ratio = max(baselinePeriod, targetPeriod) / min(baselinePeriod, targetPeriod)
            if ratio >= periodRatioLimit {
                let before = periodDescription(baselinePeriod), now = periodDescription(targetPeriod)
                let consequence = basis == .absolute
                    ? "Sample counts are not alike, so switch to shares."
                    : "Shares are comparable; sample counts are not."
                return .warning("The baseline was sampled every \(before) and this recording every \(now). \(consequence)")
            }
        }
        return .compatible
    }

    private static func periodDescription(_ milliseconds: Double) -> String {
        milliseconds == milliseconds.rounded() ? "\(Int(milliseconds)) ms" : String(format: "%.1f ms", milliseconds)
    }
}
