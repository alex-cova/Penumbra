import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// javac is the oracle for the type hints (`var` locals and `for (var …)` variables). Each snippet
/// is compiled alone with a `zzProbe()` call on the variable, which makes javac print the variable's
/// type. The provider's hint label must name the same type. The initializers are chosen so the
/// provider does not suppress the hint as obvious (`new X()`, literals, factory calls).
///
/// A snippet marks the probe with `€.` after the variable. A sample whose javac type is `Object`
/// expects no hint, since the provider reads `Object` as a failed inference.
final class JavaInlayHintOracleTests: XCTestCase {
    private struct Sample {
        let name: String
        let source: String
    }

    private static let samples: [Sample] = [
        Sample(name: "ListGet", source: """
        import java.util.List;
        class ListGet { void m(List<String> list) {
            var first = list.get(0);
            first€.
        } }
        """),
        Sample(name: "ListSize", source: """
        import java.util.List;
        class ListSize { void m(List<String> list) {
            var size = list.size();
            size€.
        } }
        """),
        Sample(name: "Split", source: """
        class Split { void m(String text) {
            var parts = text.split(",");
            parts€.
        } }
        """),
        Sample(name: "EntrySet", source: """
        import java.util.Map;
        class EntrySet { void m(Map<String, Integer> map) {
            var entries = map.entrySet();
            entries€.
        } }
        """),
        Sample(name: "OptionalGet", source: """
        import java.util.Optional;
        class OptionalGet { void m(Optional<String> held) {
            var item = held.get();
            item€.
        } }
        """),
        Sample(name: "ForEachArray", source: """
        class ForEachArray { void m(String[] words) {
            for (var word : words) {
                word€.
            }
        } }
        """),
        Sample(name: "ForEachList", source: """
        import java.util.List;
        class ForEachList { void m(List<Integer> numbers) {
            for (var number : numbers) {
                number€.
            }
        } }
        """),
        Sample(name: "LambdaForEach", source: """
        import java.util.List;
        class LambdaForEach { void m(List<String> names) {
            names.forEach(name -> {
                name€.
            });
        } }
        """),
        Sample(name: "LambdaMap", source: """
        import java.util.List;
        class LambdaMap { void m(List<String> names) {
            var lengths = names.stream().map(item -> {
                item€.
                return 1;
            }).toList();
        } }
        """),
        Sample(name: "LambdaTwoParams", source: """
        import java.util.Map;
        class LambdaTwoParams { void m(Map<String, Integer> map) {
            map.forEach((key, count) -> {
                count€.
            });
        } }
        """),
        Sample(name: "LambdaComparator", source: """
        import java.util.List;
        class LambdaComparator { void m(List<String> names) {
            names.sort((left, right) -> {
                right€.
                return 0;
            });
        } }
        """),
        Sample(name: "TryResource", source: """
        import java.nio.file.*;
        import java.util.stream.Stream;
        class TryResource { void m(Path path) throws Exception {
            try (var lines = Files.lines(path)) {
                lines€.
            }
        } }
        """),
        Sample(name: "RecordPatternInstanceof", source: """
        import java.util.List;
        class RecordPatternInstanceof {
            record Box(List<String> items, int count) {}
            void m(Object value) {
                if (value instanceof Box(var entries, var total)) {
                    entries€.
                }
            }
        }
        """),
        Sample(name: "RecordPatternPrimitive", source: """
        class RecordPatternPrimitive {
            record Box(String label, int count) {}
            void m(Object value) {
                if (value instanceof Box(var caption, var amount)) {
                    amount€.
                }
            }
        }
        """),
        Sample(name: "RecordPatternSwitch", source: """
        import java.util.List;
        class RecordPatternSwitch {
            record Pair(String first, List<Integer> second) {}
            int m(Object value) {
                switch (value) {
                    case Pair(var head, var tail) -> {
                        tail€.
                        return 1;
                    }
                    default -> { return 0; }
                }
            }
        }
        """),
        Sample(name: "StreamToList", source: """
        import java.util.List;
        class StreamToList { void m(List<String> names) {
            var upper = names.stream().map(String::toUpperCase).toList();
            upper€.
        } }
        """),
    ]

    func testTypeHintsAgreeWithJavac() async throws {
        let jdk = try ParityTestSupport.requireJDK()
        guard jdk.hasCtSym, let javac = jdk.javac else {
            throw XCTSkip("No JDK with ct.sym and javac")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("inlay-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let jdkShard = scratch.appendingPathComponent("jdk.idx")
        try JavaIndexShardWriter().write(
            try JDKCtSymRoot(installation: jdk).readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard
        )
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard))])
        let provider = JavaInlayHintProvider(
            index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache"))
        )
        await provider.setOptions(JavaInlayHintOptions(parameterNames: false, variableTypes: true, lambdaParameterTypes: true))

        var failures: [String] = []
        for sample in Self.samples {
            guard let javacType = try Self.javacType(of: sample, javac: javac, in: scratch) else {
                failures.append("\(sample.name): javac attributed no probe receiver")
                continue
            }
            let source = sample.source.replacingOccurrences(of: "€.", with: ".hashCode();")
            // The probed variable's declaration is the first whole-word occurrence of its name.
            guard let variable = Self.probedVariable(in: sample.source),
                  let declaration = try Self.firstWord(variable, in: source) else {
                failures.append("\(sample.name): no probed variable")
                continue
            }
            // The open file's own types are in the index overlay, as they are in the app.
            let own = JavaSourceStubBuilder.build(source: source, url: scratch.appendingPathComponent("T.java")).classes
            await index.setOverlay(Dictionary(uniqueKeysWithValues: own.map { ($0.qualifiedName, $0) }))
            let hints = await Self.hints(for: source, provider: provider, in: scratch)
                .filter { $0.kind == .type && $0.utf16Offset == declaration }
            let expected = JavaReceiverTypeAudit.simplified(javacType)
            if expected == "Object" {
                if !hints.isEmpty { failures.append("\(sample.name): javac Object, hint \(hints.map(\.label))") }
                continue
            }
            guard let hint = hints.first, hints.count == 1 else {
                failures.append("\(sample.name): javac \(expected), hints at \(variable) \(hints.map(\.label))")
                continue
            }
            let actual = JavaReceiverTypeAudit.simplified(String(hint.label.dropFirst(2)))
            if actual != expected { failures.append("\(sample.name): javac \(expected), hint \(actual)") }
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
    }

    private static func probedVariable(in source: String) -> String? {
        guard let marker = source.range(of: "€") else { return nil }
        let word = source[..<marker.lowerBound].reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return word.isEmpty ? nil : String(word.reversed())
    }

    /// The UTF-16 offset just after the first whole-word `word` in `source`.
    private static func firstWord(_ word: String, in source: String) throws -> Int? {
        let regex = try NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b")
        guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
        return match.range.upperBound
    }

    private static func hints(for source: String, provider: JavaInlayHintProvider, in scratch: URL) async -> [InlayHint] {
        let start = JavaNavigationText.position(utf16Offset: 0, in: source)
        let end = JavaNavigationText.position(utf16Offset: (source as NSString).length, in: source)
        let document = Document(
            url: scratch.appendingPathComponent("T.java"), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: EditorIntelligence.TextRange(start: start, end: start)),
            cursor: Cursor(position: start),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
            languageIdentifier: "java"
        )
        return await provider.inlayHints(for: document, in: EditorIntelligence.TextRange(start: start, end: end))
    }

    /// The probed variable's type: a reference type from `location: variable NAME of type T`, or a
    /// primitive from `T cannot be dereferenced`.
    private static func javacType(of sample: Sample, javac: URL, in scratch: URL) throws -> String? {
        let directory = scratch.appendingPathComponent("javac-\(sample.name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(sample.name).java")
        try sample.source.replacingOccurrences(of: "€.", with: ".zzProbe();")
            .write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = javac
        process.arguments = ["-proc:none", "-Xlint:none", "-d", directory.path, "-Xmaxerrs", "40", file.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        for pattern in [
            "symbol:\\s+method zzProbe\\(\\)\\s+location: variable \\w+ of type (.+)",
            "([\\w.$\\[\\]]+) cannot be dereferenced",
        ] {
            let regex = try NSRegularExpression(pattern: pattern)
            if let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let range = Range(match.range(at: 1), in: output) {
                return output[range].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
