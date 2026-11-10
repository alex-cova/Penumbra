import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// javac is the oracle for local-variable type inference (JLS 14.4.1). Each snippet is compiled
/// alone. A reference receiver is the type in `location: variable NAME of type TYPE`. A primitive
/// is the type named by `TYPE cannot be dereferenced`. A declaration javac rejects produces no
/// `zzProbe` location, and the engine must not invent a type for it. An anonymous class is compared
/// by a member of its body: javac spells the type `<anonymous Object>`, the engine a synthetic name.
///
/// These snippets stay out of the completion corpus, so the JDK 25 baseline is unchanged.
final class JavaVarInferenceOracleTests: XCTestCase {
    func testInferredLocalsAgreeWithJavac() async throws {
        let jdk = try ParityTestSupport.requireJDK()
        guard jdk.hasCtSym, let javac = jdk.javac else {
            throw XCTSkip("No JDK with ct.sym and javac")
        }
        let jdkShard = FileManager.default.temporaryDirectory.appendingPathComponent("var-oracle-jdk-\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(
            try JDKCtSymRoot(installation: jdk).readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard
        )
        defer { try? FileManager.default.removeItem(at: jdkShard) }

        var failures: [String] = []
        for sample in Self.samples {
            let report = try Self.compile(sample.source, named: sample.name, javac: javac)
            let engine = await Self.engine(sample.source, jdkShard: jdkShard)
            if let failure = Self.compare(sample, report: report, engine: engine) {
                failures.append(failure)
            }
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
    }

    // MARK: - Corpus

    private enum Kind {
        /// javac reports `location: variable … of type T`.
        case reference
        /// javac reports `T cannot be dereferenced`.
        case primitive
        /// javac attributes no receiver at the probe. The engine type stays nil.
        case rejected
        /// javac's location contains `anonymous`. The engine type exposes `member`.
        case anonymous(member: String)
    }

    private struct Sample {
        let name: String
        let kind: Kind
        let source: String
    }

    /// `€` sits immediately before the `.` whose receiver is typed.
    private static let samples: [Sample] = [
        Sample(name: "Opt", kind: .reference, source: """
        import java.util.Optional;
        class Opt { void m() {
            Optional<String> itemOptional = Optional.empty();
            var item = itemOptional.get();
            item€.
        } }
        """),
        Sample(name: "Chain", kind: .reference, source: """
        import java.util.Optional;
        class Chain { void m() {
            var held = Optional.of("x");
            var item = held.get();
            item€.
        } }
        """),
        Sample(name: "Standalone", kind: .reference, source: """
        import java.util.Optional;
        class Standalone { void m() { var item = Optional.of("x").get(); item€. } }
        """),
        Sample(name: "Trim", kind: .reference, source: """
        import java.util.Optional;
        class Trim { void m() { var item = Optional.of("  x  ").get().trim(); item€. } }
        """),
        Sample(name: "ListOf", kind: .reference, source: """
        import java.util.List;
        class ListOf { void m() { var list = List.of("a", "b"); list€. } }
        """),
        Sample(name: "MapOf", kind: .reference, source: """
        import java.util.Map;
        class MapOf { void m() { var map = Map.of("a", 1); map€. } }
        """),
        Sample(name: "Ctor", kind: .reference, source: """
        class Ctor { void m() { var buffer = new StringBuilder(); buffer€. } }
        """),
        Sample(name: "Array", kind: .reference, source: """
        class Array { void m() { var xs = new String[] { "a" }; xs€. } }
        """),
        Sample(name: "IntArray", kind: .reference, source: """
        class IntArray { void m() { var xs = new int[] { 1 }; xs€. } }
        """),
        Sample(name: "Cond", kind: .reference, source: """
        class Cond { void m() { boolean flag = true; var s = flag ? "a" : "b"; s€. } }
        """),
        Sample(name: "NullArm", kind: .reference, source: """
        class NullArm { void m() { boolean flag = true; var s = flag ? "a" : null; s€. } }
        """),
        Sample(name: "Switch", kind: .reference, source: """
        class Switch { void m() { var s = switch (1) { case 1 -> "a"; default -> "b"; }; s€. } }
        """),
        Sample(name: "Copy", kind: .reference, source: """
        class Copy { void m(String name) { var copy = name; copy€. } }
        """),
        Sample(name: "Cast", kind: .reference, source: """
        import java.util.function.Function;
        class Cast { void m() { var f = (Function<String, Integer>) (s -> s.length()); f€. } }
        """),
        Sample(name: "ForEach", kind: .reference, source: """
        import java.util.List;
        class ForEach { void m(List<String> items) { for (var s : items) { s€. } } }
        """),
        Sample(name: "ForField", kind: .reference, source: """
        import java.util.List;
        class ForField { List<String> items; void m() { for (var item : items) { item€. } } }
        """),
        Sample(name: "ForSameName", kind: .reference, source: """
        import java.util.List;
        class ForSameName { List<String> items; void m() { for (var items : items) { items€. } } }
        """),
        Sample(name: "Resource", kind: .reference, source: """
        import java.io.ByteArrayInputStream;
        class Resource { void m() { try (var input = new ByteArrayInputStream(new byte[0])) { input€. } } }
        """),
        Sample(name: "Anon", kind: .anonymous(member: "value"), source: """
        class Anon { void m() { var box = new Object() { int value = 1; }; box€. } }
        """),

        Sample(name: "Int", kind: .primitive, source: "class Int { void m() { var i = 1; i€. } }"),
        Sample(name: "Long", kind: .primitive, source: "class Long { void m() { var n = 1L; n€. } }"),
        Sample(name: "Double", kind: .primitive, source: "class Double { void m() { var n = 1.0; n€. } }"),
        Sample(name: "Boolean", kind: .primitive, source: "class Boolean { void m() { var n = true; n€. } }"),
        Sample(name: "Text", kind: .reference, source: "class Text { void m() { var s = \"a\"; s€. } }"),
        Sample(name: "Promo", kind: .primitive, source: """
        class Promo { void m() { boolean flag = true; var n = flag ? 1 : 2.5; n€. } }
        """),
        Sample(name: "ForInit", kind: .primitive, source: """
        class ForInit { void m() { int n = 0; for (var i = n; i < 3; i++) { i€. } } }
        """),
        Sample(name: "Nested", kind: .primitive, source: """
        class Nested { void m() { int n = 1; { var x = n; x€. } } }
        """),
        Sample(name: "ThisField", kind: .primitive, source: """
        class ThisField { int n = 1; void m() { var n = this.n; n€. } }
        """),
        Sample(name: "Method", kind: .primitive, source: """
        class Method { int n() { return 1; } void m() { var n = n(); n€. } }
        """),
        Sample(name: "Later", kind: .primitive, source: """
        class Later { void m() { var a = b; var b = 1; b€. } }
        """),

        Sample(name: "Forward", kind: .rejected, source: """
        class Forward { void m() { var a = b; var b = 1; a€. } }
        """),
        Sample(name: "Cycle", kind: .rejected, source: """
        class Cycle { void m() { var a = b; var b = a; a€. } }
        """),
        Sample(name: "Self", kind: .rejected, source: """
        class Self { int n = 1; void m() { var n = n; n€. } }
        """),
        Sample(name: "SelfAdd", kind: .rejected, source: """
        class SelfAdd { int n = 1; void m() { var n = n + 1; n€. } }
        """),
        Sample(name: "ForOwn", kind: .rejected, source: """
        class ForOwn { void m() { for (var i = i + 1;;) { i€. } } }
        """),
        Sample(name: "Lambda", kind: .rejected, source: """
        class Lambda { void m() { var f = (String s) -> s.length(); f€. } }
        """),
        Sample(name: "Reference", kind: .rejected, source: """
        class Reference { void m() { var g = String::length; g€. } }
        """),
        Sample(name: "Null", kind: .rejected, source: """
        class Null { void m() { var n = null; n€. } }
        """),
        Sample(name: "BothNull", kind: .rejected, source: """
        class BothNull { void m() { boolean flag = true; var x = flag ? null : null; x€. } }
        """),
        Sample(name: "Braces", kind: .rejected, source: """
        class Braces { void m() { var ys = { 1, 2 }; ys€. } }
        """),
        Sample(name: "Broken", kind: .rejected, source: """
        import java.util.Optional;
        class Broken { void m() {
            Optional<String> itemOptional = Optional.empty();
            var item = itemOptional.get(
            item€.
        } }
        """),
    ]

    // MARK: - Engine

    private struct Engine {
        var type: JavaTypeRef?
        var fieldNames: [String]
    }

    private static func engine(_ source: String, jdkShard: URL) async -> Engine {
        guard let marker = source.range(of: "€"), source[marker.upperBound] == "." else { return Engine(type: nil, fieldNames: []) }
        let withoutMarker = source.replacingOccurrences(of: "€", with: "")
        let dotOffset = source.utf8.distance(from: source.utf8.startIndex, to: marker.lowerBound.samePosition(in: source.utf8)!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("var-oracle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return Engine(type: nil, fieldNames: [])
        }
        let fileURL = directory.appendingPathComponent("Sample.java")
        guard (try? withoutMarker.write(to: fileURL, atomically: true, encoding: .utf8)) != nil,
              let tree = JavaSyntaxParser().parse(withoutMarker) else {
            return Engine(type: nil, fieldNames: [])
        }
        let file = JavaSourceStubBuilder.build(source: withoutMarker, url: fileURL)
        let projectShard = directory.appendingPathComponent("project.idx")
        guard (try? JavaIndexShardWriter().write(file.classes, stamp: JavaStamp(size: 0, modificationDate: 0), to: projectShard)) != nil,
              let projectReader = try? JavaIndexShardReader(url: projectShard),
              let jdkReader = try? JavaIndexShardReader(url: jdkShard) else {
            return Engine(type: nil, fieldNames: [])
        }
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: projectReader),
            .init(precedence: 3, reader: jdkReader)
        ])
        let enclosing = file.classes.first.map { [$0.qualifiedName] } ?? []
        let context = JavaResolutionContext(
            packageName: file.packageName, imports: file.imports, enclosingTypeQualifiedNames: enclosing
        )
        return await JavaAnonymousClass.$registry.withValue(JavaAnonymousClass.Registry(fileURL: fileURL)) {
            let type = await JavaExpressionTyper.typeOfReceiver(
                source: withoutMarker, realTree: tree, dotOffset: dotOffset, context: context, index: index
            )
            guard let type else { return Engine(type: nil, fieldNames: []) }
            let members = await JavaMemberLookup.members(of: type, mode: .instance, context: context, index: index)
            let names = members.compactMap { member -> String? in
                if case .field(let field, _) = member { return field.name }
                return nil
            }
            return Engine(type: type, fieldNames: names)
        }
    }

    // MARK: - javac

    private struct Report {
        var locationType: String?
        var dereferenced: String?
    }

    private static func compile(_ source: String, named name: String, javac: URL) throws -> Report {
        let probed = source.replacingOccurrences(of: "€.", with: ".zzProbe();")
        // A probe that was the last token of a block already gained its semicolon above.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("var-javac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("\(name).java")
        try probed.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = javac
        process.arguments = ["-proc:none", "-Xlint:none", "-d", directory.path, "-Xmaxerrs", "40", file.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let location = try NSRegularExpression(
            pattern: "symbol:\\s+method zzProbe\\(\\)\\s+location: variable \\w+ of type (.+)"
        )
        var locationType: String?
        if let match = location.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let range = Range(match.range(at: 1), in: output) {
            locationType = output[range].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let dereference = try NSRegularExpression(pattern: "([\\w.$\\[\\]]+) cannot be dereferenced")
        var dereferenced: String?
        if let match = dereference.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let range = Range(match.range(at: 1), in: output) {
            dereferenced = String(output[range])
        }
        return Report(locationType: locationType, dereferenced: dereferenced)
    }

    // MARK: - Comparison

    private static func compare(_ sample: Sample, report: Report, engine: Engine) -> String? {
        switch sample.kind {
        case .reference:
            guard let javacType = report.locationType else {
                return "\(sample.name): javac attributed no receiver"
            }
            guard let type = engine.type else {
                return "\(sample.name): engine nil, javac \(javacType)"
            }
            let expected = JavaReceiverTypeAudit.simplified(javacType)
            let actual = JavaReceiverTypeAudit.simplified(JavaReceiverTypeAudit.describe(type))
            return expected == actual ? nil : "\(sample.name): javac \(expected), engine \(actual)"
        case .primitive:
            guard let javacType = report.dereferenced else {
                return "\(sample.name): javac did not reject a dereference\(report.locationType.map { " (location \($0))" } ?? "")"
            }
            guard let type = engine.type else {
                return "\(sample.name): engine nil, javac \(javacType)"
            }
            let actual = JavaReceiverTypeAudit.simplified(JavaReceiverTypeAudit.describe(type))
            let expected = JavaReceiverTypeAudit.simplified(javacType)
            return expected == actual ? nil : "\(sample.name): javac \(expected), engine \(actual)"
        case .rejected:
            if report.locationType != nil || report.dereferenced != nil {
                return "\(sample.name): javac attributed \(report.locationType ?? report.dereferenced ?? "")"
            }
            guard engine.type == nil else {
                return "\(sample.name): engine invented \(JavaReceiverTypeAudit.describe(engine.type!))"
            }
            return nil
        case .anonymous(let member):
            guard let javacType = report.locationType, javacType.contains("anonymous") else {
                return "\(sample.name): javac location \(report.locationType ?? "nil") is not anonymous"
            }
            guard let type = engine.type, type.erasedQualifiedName?.contains(JavaAnonymousClass.marker) == true else {
                return "\(sample.name): engine \(engine.type.map { JavaReceiverTypeAudit.describe($0) } ?? "nil")"
            }
            return engine.fieldNames.contains(member) ? nil : "\(sample.name): members \(engine.fieldNames) lack \(member)"
        }
    }
}
