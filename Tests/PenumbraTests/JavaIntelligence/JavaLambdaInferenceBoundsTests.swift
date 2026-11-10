import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// Inference for a lambda parameter types the sibling lambdas of its call, and a reference to an
/// outer lambda's parameter inside them asks the enclosing call the same question. These tests
/// pin that the cost stays small and does not blow up with nesting.
final class JavaLambdaInferenceBoundsTests: XCTestCase {
    /// `Stream.of(a).map(x1 -> Stream.of(x1, …).map(x2 -> … { xN.| }))`, every level naming every
    /// outer parameter, so every level has outer lambda parameters to resolve.
    private func nested(depth: Int) -> (text: String, caret: Int) {
        var body = ""
        for level in 1...depth {
            let outer = (1..<level).map { "x\($0)" }.joined(separator: ", ")
            let source = level == 1 ? "names" : "Stream.of(\(outer)).toList()"
            body += "\(source).stream().map(x\(level) -> "
        }
        let marker = "/*|*/"
        body += "{ x\(depth).\(marker) }" + String(repeating: ")", count: depth)
        let text = "import java.util.*;\nimport java.util.stream.*;\nclass Nest {\n    void test(List<String> names) {\n        \(body);\n    }\n}\n"
        let caret = (text as NSString).range(of: marker).location
        return (text.replacingOccurrences(of: marker, with: ""), caret)
    }

    /// `pipe("x", s1 -> s1 + t0…, t1 -> pipe("x", s2 -> s2 + t1…, t2 -> … { tN.| }))`: every call has
    /// a sibling lambda (`s -> …`) that names all the outer parameters, and the caret's parameter is
    /// only typed by asking each enclosing call, whose sibling must be typed to answer.
    private func siblingNest(depth: Int) -> (text: String, caret: Int) {
        var body = ""
        for level in 1...depth {
            let outer = (1..<level).map { " + t\($0)" }.joined()
            body += "pipe(\"x\", s\(level) -> s\(level)\(outer), t\(level) -> "
        }
        let marker = "/*|*/"
        body += "{ t\(depth).\(marker) }" + String(repeating: ")", count: depth)
        let text = "import java.util.*;\nimport java.util.function.*;\nclass Nest {\n    static <A, B, C> C pipe(A a, Function<A, B> f, Function<B, C> g) { return null; }\n    void test() {\n        \(body);\n    }\n}\n"
        let caret = (text as NSString).range(of: marker).location
        return (text.replacingOccurrences(of: marker, with: ""), caret)
    }

    func testNestedLambdaDepthDoesNotBlowUp() async throws {
        try await measure("single", depths: [1, 4, 8, 14], build: nested(depth:))
    }

    func testNestedSiblingLambdasDoNotBlowUp() async throws {
        try await measure("sibling", depths: [1, 4, 8, 14], build: siblingNest(depth:))
    }

    private func measure(_ label: String, depths: [Int] = [1, 2, 4, 6, 8], build: (Int) -> (text: String, caret: Int)) async throws {
        let corpus = try await JavaCompletionCorpusTests.sharedIndex()
        var timings: [(Int, Double)] = []
        for depth in depths {
            let (text, caretOffset) = build(depth)
            // Member lookup reads a source class's declaring file from disk to resolve its signatures.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nest-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("Nest.java")
            try text.write(to: url, atomically: true, encoding: .utf8)
            let before = (text as NSString).substring(to: caretOffset).components(separatedBy: "\n")
            let position = TextPosition(line: before.count - 1, column: (before.last ?? "").utf16.count, utf16Offset: caretOffset)
            let document = Document(
                id: DocumentID(), url: url, displayName: url.lastPathComponent,
                contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
                viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
            )
            let context = makeCompletionContext(document: document, trigger: .manual, mode: .basic)
            // Umbra keeps the open document's own classes in the overlay; the corpus runner does the same.
            let parseable = JavaCompletionProvider.repairedText(text, insertingDummyAt: caretOffset)
            let ownStubs = JavaSourceStubBuilder.build(source: parseable, url: url).classes
            await corpus.index.setOverlay(Dictionary(ownStubs.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first }))
            let provider = JavaCompletionProvider(index: corpus.index)
            let clock = ContinuousClock()
            let start = clock.now
            let diagnosis = await provider.diagnose(context: context)
            let elapsed = clock.now - start
            timings.append((depth, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
            // Every level's parameter is a `String`, the stream element type all the way down. Past
            // the depth cap inference may give up and the parameter reads as `Object`; it must never
            // be anything else.
            let name = diagnosis?.receiverType.flatMap { type -> String? in
                if case .classType(let name, _, _) = type { return name } else { return nil }
            }
            if depth <= 8 {
                XCTAssertEqual(name, "java.lang.String", "depth \(depth)")
            } else {
                XCTAssertTrue(["java.lang.String", "java.lang.Object"].contains(name ?? ""), "depth \(depth): \(name ?? "nil")")
            }
        }
        print("NEST \(label) timings (debug build): " + timings.map { "d\($0.0)=\(String(format: "%.0f", $0.1 * 1000))ms" }.joined(separator: " "))
        XCTAssertLessThan(timings.last!.1, 1.0, "deepest nest took \(timings.last!.1) s")
    }
}
