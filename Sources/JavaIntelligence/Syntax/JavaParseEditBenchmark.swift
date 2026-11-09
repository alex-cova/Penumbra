import Foundation
import LanguageSyntax

/// Times the pieces of "turn the previous tree into the tree for this text" separately, for
/// `PerfHarness java-parse-edit`. It follows the editor's protocol: one parser kept across
/// requests, each step edits the tree the previous step produced. `diff` is `ParseEdit.diff` as
/// shipped; the other columns are the pieces `JavaStubReuse.reparse` runs around it.
@_spi(Benchmarks)
public final class JavaParseEditBenchmark {
    public struct Timings {
        /// `Array(new.utf8)`.
        public var toBytes = 0.0
        /// `ParseEdit.diff` as called today.
        public var diff = 0.0
        /// `ParseEdit.referenceDiff`: the original implementation, the oracle.
        public var referenceDiff = 0.0
        /// `SyntaxTree.copy()` and `apply(edit)`.
        public var copyApply = 0.0
        /// `parseIncremental` on the edited tree (includes its own copy of the text as bytes).
        public var incrementalParse = 0.0
        /// The primitives inside `diff`, timed on their own (prefix and suffix compare, one newline count).
        public var prefixScan = 0.0
        public var suffixScan = 0.0
        public var newlineScan = 0.0
        public var edit: (start: Int, oldEnd: Int, newEnd: Int) = (0, 0, 0)
        public var matchesReference = true
        public var total: Double { toBytes + diff + copyApply + incrementalParse }
    }

    private let parser = JavaSyntaxParser()
    private var tree: JavaSyntaxTree

    public init?(source: String) {
        let parser = self.parser
        guard let tree = parser.parse(source) else { return nil }
        self.tree = tree
    }

    public func advance(to text: String) -> Timings? {
        var timings = Timings()
        func time(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
        }
        var newBytes: [UInt8] = []
        timings.toBytes = time { newBytes = Array(text.utf8) }
        var edit: ParseEdit?
        timings.diff = time { edit = ParseEdit.diff(from: tree.sourceBytes, to: newBytes) }
        var reference: ParseEdit?
        timings.referenceDiff = time { reference = ParseEdit.referenceDiff(from: tree.sourceBytes, to: newBytes) }
        guard let edit, let reference else { return nil }
        timings.edit = (edit.startByte, edit.oldEndByte, edit.newEndByte)
        timings.matchesReference = edit.isEqual(to: reference)

        tree.sourceBytes.withUnsafeBufferPointer { old in
            newBytes.withUnsafeBufferPointer { new in
                var prefix = 0
                timings.prefixScan = time { prefix = ParseEdit.commonPrefixLength(old, new, limit: min(old.count, new.count)) }
                timings.suffixScan = time { _ = ParseEdit.commonSuffixLength(old, new, limit: min(old.count, new.count) - prefix) }
                timings.newlineScan = time { _ = ParseEdit.newlineCount(in: old, from: 0, to: prefix) }
            }
        }

        var edited: JavaSyntaxTree?
        timings.copyApply = time {
            let copy = tree.copy()
            copy.apply(edit)
            edited = copy
        }
        guard let edited else { return nil }
        var next: JavaSyntaxTree?
        timings.incrementalParse = time { next = parser.parseIncremental(oldTree: edited, source: text) }
        guard let next else { return nil }
        tree = next
        return timings
    }
}
