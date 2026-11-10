import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// The jOOL regression (`Agg.taking`): `Collector.of(() -> new ArrayList<T>(), (l, v) -> l.|, …)`.
/// `l` is typed by the *other* lambda's return value in the same generic call. Runs on the real
/// jOOL 0.9.15 checkout that the quality harness uses (`~/Library/Caches/umbra-differential`);
/// skipped when it is not there.
final class JavaLambdaContextInferenceJOOLTests: XCTestCase {
    private func jool() throws -> URL {
        let root = try JavaDifferentialHarness.cachesRoot()
            .appendingPathComponent("jOOL-version-0.9.15/jOOL-java-8/src/main/java", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("jOOL checkout missing") }
        return root
    }

    /// `Agg.taking`: `l` in `(l, v) -> { if (l.size() < n) … }` is bound by the supplier lambda
    /// (`() -> new ArrayList<T>()`) of the same `Collector.of(…)` call. The finisher is
    /// `Seq::seq`, which only the four-argument overload with a `Function` can take: the other
    /// overload ends in the varargs `Characteristics...`, and a method reference is not one.
    func testLambdaParameterIsTypedBySiblingLambdaOfTheSameCall() async throws {
        let installation = try ParityTestSupport.requireJDK()
        let root = try jool()
        let jdkShard = try JavaDifferentialHarness.writeJDKShard(installation: installation)
        let world = try await JavaDifferentialHarness.makeWorld(sourceRoot: root, jdkShard: jdkShard, installation: installation)
        let file = root.appendingPathComponent("org/jooq/lambda/Agg.java")
        var text = try String(contentsOf: file, encoding: .utf8)
        let marker = "if (l.size() < n)"
        let range = try XCTUnwrap(text.range(of: marker))
        let dot = text.index(range.lowerBound, offsetBy: "if (l.".count)
        text.replaceSubrange(dot..<text.index(dot, offsetBy: "size".count), with: "")
        let utf16 = text.utf16.distance(from: text.startIndex, to: dot)
        let caret = JavaDifferentialHarness.position(in: text, utf16: utf16)
        let context = CompletionContext(
            document: JavaDifferentialHarness.document(url: file, text: text, caret: caret),
            cursor: Cursor(position: caret), trigger: .manual, prefix: "",
            range: EditorIntelligence.TextRange(start: caret, end: caret)
        )

        let diagnosed = await world.completion.diagnose(context: context)
        let diagnosis = try XCTUnwrap(diagnosed)
        let receiver = try XCTUnwrap(diagnosis.receiverType)
        // javac: `location: variable l of type ArrayList<T>`.
        XCTAssertEqual(JavaExpressionTyperTestSupport.describe(receiver), "java.util.ArrayList<T>")

        let items = await world.completion.provide(context: context)
        let labels = Set(items.map(\.label))
        XCTAssertTrue(labels.isSuperset(of: ["size", "add", "addAll", "ensureCapacity"]), "ArrayList members missing")
        // What the wrong receiver (`Seq<T>`) used to offer in their place.
        XCTAssertTrue(labels.isDisjoint(with: ["skip", "slice", "sorted", "crossJoin", "transform"]), "Seq members offered")
    }
}

enum JavaExpressionTyperTestSupport {
    static func describe(_ type: JavaTypeRef) -> String {
        switch type {
        case .classType(let name, let arguments, _):
            guard !arguments.isEmpty else { return name }
            return "\(name)<\(arguments.map(describe).joined(separator: ","))>"
        case .typeVariable(let name): return name
        default: return String(describing: type)
        }
    }

    private static func describe(_ argument: JavaTypeArgument) -> String {
        if case .type(let type) = argument { return describe(type) }
        return "?"
    }
}
