import XCTest
@testable import JavaIntelligence

/// javac as the independent oracle for the lambda inference corpus (`cases/Lam*.java`) and for the known-gap cases
/// the generic type audit proposed (`cases/Gap*.java`, tagged `gap:` until their change lands).
///
/// A case states the receiver's full type in `//! receiverType:`. Here each case is compiled with the
/// caret replaced by a member that does not exist (`zzProbe()`); javac's `cannot find symbol` names
/// the receiver it attributed (`location: variable l of type ArrayList<T>`), and that has to match the
/// case. So the expectations the engine is held to are javac's, not this repository's reading of the
/// JLS. Skipped without a JDK.
///
/// Unfinished code is checked too: a case may say what completes it for javac with
/// `//! oracle-completion: <text>` (the text compiled in place of the caret, for instance `zzProbe();});`
/// to close an open lambda block and call), so javac attributes the very code the developer was typing.
/// Cases that carry `//! oracle:` are excluded on purpose, each saying why (a type variable that the engine
/// reports as its bound).
final class JavaLambdaInferenceOracleTests: XCTestCase {
    func testLambdaCorpusReceiverTypesAgreeWithJavac() throws {
        let jdk = try ParityTestSupport.requireJDK()
        let javac = try XCTUnwrap(jdk.javac)
        let root = CorpusIndex.directory
        let cases = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cases"), includingPropertiesForKeys: nil)
            .filter { ($0.lastPathComponent.hasPrefix("Lam") || $0.lastPathComponent.hasPrefix("Gap")) && $0.pathExtension == "java" }
            .sorted { $0.path < $1.path }

        var checked = 0
        var disagreements: [String] = []
        for file in cases {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard let expected = Self.directive("receiverType", in: source), !source.contains("//! oracle:") else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            guard let reported = try Self.receiverReportedByJavac(
                for: source, named: name, completion: Self.directive("oracle-completion", in: source),
                javac: javac, sourcepath: root.appendingPathComponent("project")
            ) else {
                disagreements.append("\(name): javac attributed no receiver")
                continue
            }
            checked += 1
            if Self.simplified(expected) != reported.replacingOccurrences(of: " ", with: "") {
                disagreements.append("\(name): case says \(expected), javac says \(reported)")
            }
        }
        XCTAssertGreaterThan(checked, 70, "the corpus lost its lambda cases")
        XCTAssertEqual(disagreements, [])
    }

    // MARK: -

    private static func directive(_ key: String, in source: String) -> String? {
        for line in source.split(whereSeparator: \.isNewline) where line.hasPrefix("//! \(key):") {
            return line.dropFirst("//! \(key):".count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// `java.util.Map.Entry<java.lang.String, java.lang.Integer>` as javac prints it:
    /// `Entry<String,Integer>`.
    private static func simplified(_ type: String) -> String {
        let qualifier = try! NSRegularExpression(pattern: "(?:[A-Za-z_][A-Za-z0-9_]*\\.)+(?=[A-Z])")
        let range = NSRange(type.startIndex..., in: type)
        return qualifier.stringByReplacingMatches(in: type, range: range, withTemplate: "").replacingOccurrences(of: " ", with: "")
    }

    /// Compiles `source` with the caret written as an unknown member and reads the receiver type
    /// out of javac's `cannot find symbol` message. A block-bodied lambda `{ x.| }` is written as
    /// the expression lambda `x.zzProbe()`: a block holding only that call can only be a `void`
    /// lambda, which would take the call out of the overloads that expect a value.
    private static func receiverReportedByJavac(
        for source: String, named name: String, completion: String?, javac: URL, sourcepath: URL
    ) throws -> String? {
        var probed = source
        if let completion {
            probed = probed.replacingOccurrences(of: "/*|*/", with: completion)
        } else {
            let block = try NSRegularExpression(pattern: "\\{ (\\w+)\\./\\*\\|\\*/ \\}")
            probed = block.stringByReplacingMatches(
                in: probed, range: NSRange(probed.startIndex..., in: probed), withTemplate: "$1.zzProbe()"
            )
            probed = probed.replacingOccurrences(of: "/*|*/", with: "zzProbe();")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lambda-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("\(name).java")
        try probed.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = javac
        process.arguments = ["-proc:none", "-Xlint:none", "-sourcepath", sourcepath.path, "-d", directory.path, "-Xmaxerrs", "200", file.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let pattern = try NSRegularExpression(pattern: "symbol:\\s+method zzProbe\\(\\)\\n\\s+location: (?:variable \\w+ of type |class |interface )?(.+)")
        guard let match = pattern.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return output[range].trimmingCharacters(in: .whitespaces)
    }
}
