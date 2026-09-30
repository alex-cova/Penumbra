import Foundation

/// One element a stage of a traced stream saw.
public struct JavaStreamTraceElement: Sendable, Equatable {
    /// When the stage saw it: one counter for the whole run, so an element's successors in the next
    /// stage have later times than it.
    public let time: Int64
    public let value: String
    /// Equal for the same object in two stages, and for equal primitive values.
    public let identity: String

    public init(time: Int64, value: String, identity: String) {
        self.time = time
        self.value = value
        self.identity = identity
    }
}

/// A Java stream pipeline found in source, like IntelliJ's stream debugger sees one: a source
/// (`list.stream()`), intermediate operations (`filter`, `map`, …), and a terminal operation.
public struct JavaStreamChain: Sendable, Equatable {
    public struct Operation: Sendable, Equatable {
        public let name: String
        /// `.map(x -> x * 2)`, as written (line breaks folded).
        public let text: String
    }

    /// The expression up to and including the call that makes the stream.
    public let source: String
    /// A short name for the source stage (`stream()`, `IntStream.range(…)`).
    public let sourceName: String
    public let intermediates: [Operation]
    public let terminal: Operation
    /// 1-based lines the chain spans.
    public let lines: ClosedRange<Int>

    /// Names for the stages the trace records, in order: the source, then each intermediate.
    public var stageNames: [String] {
        [sourceName] + intermediates.map(\.name)
    }

    static let sourceMethods: Set<String> = [
        "stream", "parallelStream", "chars", "codePoints", "lines", "splitAsStream", "ints", "longs", "doubles"
    ]
    static let staticSourceMethods: Set<String> = ["of", "ofNullable", "range", "rangeClosed", "iterate", "generate", "concat", "empty", "stream"]
    static let staticSourceTypes: Set<String> = [
        "Stream", "IntStream", "LongStream", "DoubleStream", "Arrays", "StreamSupport",
        "java.util.stream.Stream", "java.util.stream.IntStream", "java.util.stream.LongStream",
        "java.util.stream.DoubleStream", "java.util.Arrays", "java.util.stream.StreamSupport"
    ]
    static let intermediateMethods: Set<String> = [
        "filter", "map", "mapToInt", "mapToLong", "mapToDouble", "mapToObj", "flatMap", "flatMapToInt",
        "flatMapToLong", "flatMapToDouble", "mapMulti", "distinct", "sorted", "peek", "limit", "skip",
        "takeWhile", "dropWhile", "boxed", "asLongStream", "asDoubleStream", "parallel", "sequential", "unordered"
    ]
    static let terminalMethods: Set<String> = [
        "forEach", "forEachOrdered", "toArray", "reduce", "collect", "toList", "min", "max", "count",
        "anyMatch", "allMatch", "noneMatch", "findFirst", "findAny", "sum", "average", "summaryStatistics", "iterator"
    ]
    static let voidTerminals: Set<String> = ["forEach", "forEachOrdered"]
    /// Operations that reorder or drop elements by value, so an output links to its input by
    /// identity rather than by time.
    static let identityLinkedOperations: Set<String> = ["sorted", "distinct"]

    /// The chains on `line` (1-based) of `source`, or that span it, outermost first.
    public static func chains(onLine line: Int, in source: String) -> [JavaStreamChain] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let bytes = tree.sourceBytes
        guard let range = JavaSourceLines.byteRange(ofLine: line, in: bytes) else { return [] }
        var tops: [SyntaxNode] = []
        collectTops(tree.rootNode, lineRange: range, into: &tops)
        var seen = Set<Range<Int>>()
        var result: [JavaStreamChain] = []
        for top in tops where seen.insert(top.byteRange).inserted {
            if let chain = chain(from: top, bytes: bytes) { result.append(chain) }
        }
        return result
    }

    /// The outermost `a.b().c()` invocations that touch the line: a method invocation whose parent
    /// is not a method invocation holding it as its `object`.
    private static func collectTops(_ node: SyntaxNode, lineRange: Range<Int>, into tops: inout [SyntaxNode]) {
        guard node.endByte > lineRange.lowerBound, node.startByte <= lineRange.upperBound else { return }
        if node.type == "method_invocation" {
            let parent = node.parent
            let isObjectOfParent = parent?.type == "method_invocation" && parent?.child(byFieldName: "object")?.byteRange == node.byteRange
            if !isObjectOfParent { tops.append(node) }
        }
        for child in node.namedChildren {
            collectTops(child, lineRange: lineRange, into: &tops)
        }
    }

    private struct Call {
        let name: String
        let node: SyntaxNode
        /// `.name(args)` as written.
        let suffix: String
    }

    private static func chain(from top: SyntaxNode, bytes: [UInt8]) -> JavaStreamChain? {
        // Flatten `root.a().b().c()` into [a, b, c] and the root expression.
        var calls: [Call] = []
        var current: SyntaxNode? = top
        var root: SyntaxNode?
        while let node = current, node.type == "method_invocation" {
            guard let name = node.child(byFieldName: "name") else { return nil }
            let object = node.child(byFieldName: "object")
            let suffixStart = object.map { $0.endByte } ?? node.startByte
            let suffix = folded(String(decoding: bytes[suffixStart..<node.endByte], as: UTF8.self))
            calls.insert(Call(name: name.text, node: node, suffix: suffix), at: 0)
            root = object
            current = object
        }
        guard calls.count >= 2, let terminal = calls.last, terminalMethods.contains(terminal.name) else { return nil }
        // The stream starts at the last source call before the operations.
        var sourceIndex: Int?
        for (index, call) in calls.enumerated().dropLast() {
            let isStaticSource = index == 0 && staticSourceMethods.contains(call.name)
                && root.map { staticSourceTypes.contains($0.text) } == true
            if sourceMethods.contains(call.name) || isStaticSource {
                sourceIndex = index
            } else if sourceIndex != nil {
                break
            }
        }
        guard let sourceIndex else { return nil }
        let intermediates = calls[(sourceIndex + 1)..<(calls.count - 1)]
        guard intermediates.allSatisfy({ intermediateMethods.contains($0.name) }) else { return nil }
        let sourceNode = calls[sourceIndex].node
        let sourceText = folded(sourceNode.text)
        let sourceName: String = {
            if let root, sourceIndex == 0, staticSourceTypes.contains(root.text) {
                return "\(root.text.split(separator: ".").last ?? "").\(calls[0].name)(…)"
            }
            return "\(calls[sourceIndex].name)()"
        }()
        let startLine = JavaSourceLines.line(ofByte: top.startByte, in: bytes)
        let endLine = JavaSourceLines.line(ofByte: max(top.startByte, top.endByte - 1), in: bytes)
        return JavaStreamChain(
            source: sourceText,
            sourceName: sourceName,
            intermediates: intermediates.map { Operation(name: $0.name, text: $0.suffix) },
            terminal: Operation(name: terminal.name, text: terminal.suffix),
            lines: startLine...endLine
        )
    }

    private static func folded(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// The chain rewritten to record what each stage sees: a `peek` after the source and after
    /// every intermediate operation adds `{time, value}` to that stage's list. It evaluates to an
    /// `Object[]` holding each stage's records as an `Object[]`, then the terminal result (null
    /// for `forEach`). The chain runs again, side effects included, as in IntelliJ.
    public func tracedExpression() -> String {
        let stageCount = intermediates.count + 1
        var body = "final java.util.concurrent.atomic.AtomicLong __umbraTime = new java.util.concurrent.atomic.AtomicLong(); "
        for stage in 0..<stageCount {
            body += "final java.util.List<Object[]> __umbraStage\(stage) = new java.util.ArrayList<>(); "
        }
        func peek(_ stage: Int) -> String {
            ".peek(__umbraValue -> __umbraStage\(stage).add(new Object[] { __umbraTime.incrementAndGet(), __umbraValue }))"
        }
        var pipeline = source + peek(0)
        for (index, operation) in intermediates.enumerated() {
            pipeline += operation.text + peek(index + 1)
        }
        pipeline += terminal.text
        if Self.voidTerminals.contains(terminal.name) {
            body += "\(pipeline); Object __umbraResult = null; "
        } else {
            body += "Object __umbraResult = \(pipeline); "
        }
        let stages = (0..<stageCount).map { "__umbraStage\($0).toArray()" }.joined(separator: ", ")
        body += "return new Object[] { \(stages), __umbraResult };"
        return "((java.util.function.Supplier<Object[]>) () -> { \(body) }).get()"
    }

    /// For each element of stage `index + 1`, the element of stage `index` it came from. Most
    /// operations handle one element at a time, so an output comes from the latest input seen
    /// before it; `sorted` and `distinct` see every element first, so theirs link by identity.
    public func links(from inputs: [JavaStreamTraceElement], to outputs: [JavaStreamTraceElement], operation: String) -> [Int?] {
        if Self.identityLinkedOperations.contains(operation) {
            var available: [String: [Int]] = [:]
            for (index, element) in inputs.enumerated() { available[element.identity, default: []].append(index) }
            return outputs.map { output in
                guard var candidates = available[output.identity], !candidates.isEmpty else { return nil }
                let first = candidates.removeFirst()
                available[output.identity] = candidates
                return first
            }
        }
        return outputs.map { output in
            // Inputs are in time order: the last one before the output.
            var low = 0
            var high = inputs.count
            while low < high {
                let mid = (low + high) / 2
                if inputs[mid].time < output.time { low = mid + 1 } else { high = mid }
            }
            return low == 0 ? nil : low - 1
        }
    }
}
