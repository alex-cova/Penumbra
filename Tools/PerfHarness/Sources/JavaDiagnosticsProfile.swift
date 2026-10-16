import Foundation
import EditorIntelligence
import JavaIntelligence
import LanguageSyntax

/// Error-highlighting parity harness: warning survival on half-typed files.
///
///   swift run -c release PerfHarness java-diagnostics survival synthetic [--lines N]
///   swift run -c release PerfHarness java-diagnostics survival <directory> [--lines N]
///
/// Survival: run inspections on valid text, inject `foo(` as the first statement of one
/// method (a half-typed edit that breaks the tree), re-run, and count baseline findings
/// outside the edited member whose identity (`source`, `code`, `message`, `severity`)
/// survives. A pure range shift is not churn. Phase 1 target: imports survive at 100%.
enum JavaDiagnosticsProfile {
    static func runSurvival(pathOrSynthetic: String, lines: Int) throws {
        let sources: [(name: String, text: String)]
        if pathOrSynthetic == "synthetic" || pathOrSynthetic == "-" {
            sources = [(name: "synthetic", text: syntheticWithUnusedImports(lines: lines))]
        } else {
            sources = try javaSources(under: pathOrSynthetic, lines: lines)
            if sources.isEmpty {
                FileHandle.standardError.write(
                    "java-diagnostics survival: no .java files under \(pathOrSynthetic)\n".data(using: .utf8)!)
                return
            }
        }
        var totalOutside = 0
        var totalSurvived = 0
        var totalImportsOutside = 0
        var totalImportsSurvived = 0
        for source in sources {
            let result = try SurvivalResult(sourceName: source.name, text: source.text)
            totalOutside += result.outside
            totalSurvived += result.survived
            totalImportsOutside += result.importsOutside
            totalImportsSurvived += result.importsSurvived
            print(
                "stage java_diagnostics_survival file=\(source.name) baseline=\(result.baseline) "
                    + "outside=\(result.outside) survived=\(result.survived) "
                    + "rate=\(formatRate(result.survived, of: result.outside)) "
                    + "imports=\(result.importsSurvived)/\(result.importsOutside)"
            )
        }
        print(
            "stage java_diagnostics_survival_total files=\(sources.count) outside=\(totalOutside) "
                + "survived=\(totalSurvived) rate=\(formatRate(totalSurvived, of: totalOutside)) "
                + "imports=\(totalImportsSurvived)/\(totalImportsOutside)"
        )
    }

    /// The `java-inspections` synthetic fixture plus two unused imports, so the valid text
    /// has import findings to survive the injected syntax error.
    static func syntheticWithUnusedImports(lines: Int) -> String {
        let base = JavaInspectionsProfile.syntheticJava(lines: lines)
        return base.replacingOccurrences(
            of: "import java.util.*;",
            with: "import java.util.*;\nimport java.util.List;\nimport java.util.ArrayList;"
        )
    }

    private static func javaSources(under directory: String, lines: Int) throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: directory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw DiagnosticsProfileFailure(message: "cannot enumerate \(directory)")
        }
        var sources: [(name: String, text: String)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "java" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            sources.append((name: url.path, text: text))
            if sources.count >= 200 { break }
        }
        return sources
    }

    private static func formatRate(_ survived: Int, of total: Int) -> String {
        guard total > 0 else { return "n/a" }
        return String(format: "%.2f", Double(survived) / Double(total))
    }
}

/// One file's survival run: baseline findings, then findings after injecting `foo(` into
/// the first method body, compared by identity outside the edited member.
private struct SurvivalResult {
    let baseline: Int
    let outside: Int
    let survived: Int
    let importsOutside: Int
    let importsSurvived: Int

    init(sourceName: String, text: String) throws {
        let baselineDiagnostics = try Self.analyze(text: text, url: Self.url(for: sourceName))
        baseline = baselineDiagnostics.count
        guard let tree = JavaSyntaxParser().parse(text),
            let member = Self.firstEditableMember(in: tree)
        else {
            outside = 0
            survived = 0
            importsOutside = 0
            importsSurvived = 0
            return
        }
        let bytes = Array(text.utf8)
        let memberLines = Self.lineRange(of: member.memberBytes, in: bytes)
        let outsideBaseline = baselineDiagnostics.filter { !memberLines.contains($0.range.start.line) }
        let brokenBytes = bytes[..<member.insertionByte] + Array("\n                foo(".utf8) + bytes[member.insertionByte...]
        let broken = String(decoding: brokenBytes, as: UTF8.self)
        let brokenIdentities = Set(try Self.analyze(text: broken, url: Self.url(for: sourceName)).map(Self.identity))
        outside = outsideBaseline.count
        survived = outsideBaseline.filter { brokenIdentities.contains(Self.identity($0)) }.count
        let importBaseline = outsideBaseline.filter { $0.code == "unused-import" || $0.code == "duplicate-import" }
        importsOutside = importBaseline.count
        importsSurvived = importBaseline.filter { brokenIdentities.contains(Self.identity($0)) }.count
    }

    private static func url(for sourceName: String) -> URL {
        sourceName == "synthetic"
            ? URL(fileURLWithPath: "/perf/Survival.java")
            : URL(fileURLWithPath: sourceName)
    }

    /// Index-free rules only: an empty index cannot resolve `String`, so the two
    /// index-backed rules would report noise instead of measuring survival.
    private static func analyze(text: String, url: URL) throws -> [Diagnostic] {
        let rules = Set(JavaInspectionRule.allCases).subtracting([.unresolvedType, .unresolvedImport])
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        let box = DiagnosticsBlockingBox<[Diagnostic]>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let service = JavaInspectionService(index: JavaIndex(), enabledRules: rules, idleDelay: .milliseconds(1))
            await service.setResultHandler { _, diagnostics in
                box.value = diagnostics
                semaphore.signal()
            }
            await service.analyzeNow(document, force: true)
        }
        semaphore.wait()
        guard let diagnostics = box.value else {
            throw DiagnosticsProfileFailure(message: "inspection pass produced no result")
        }
        return diagnostics
    }

    /// The first method or constructor body: insertion goes right after its `{`,
    /// so the edit breaks exactly this member.
    private static func firstEditableMember(in tree: JavaSyntaxTree) -> (insertionByte: Int, memberBytes: Range<Int>)? {
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "method_declaration" || node.type == "constructor_declaration",
                let body = node.firstNamedChild(ofType: "block")
            {
                return (body.startByte + 1, node.byteRange)
            }
            stack.append(contentsOf: node.namedChildren.reversed())
        }
        return nil
    }

    private static func lineRange(of bytes: Range<Int>, in utf8: [UInt8]) -> Range<Int> {
        func line(atByteOffset offset: Int) -> Int {
            utf8.prefix(offset).reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        }
        return line(atByteOffset: bytes.lowerBound)..<line(atByteOffset: min(bytes.upperBound, utf8.count)) + 1
    }

    /// Identity for survival and churn: a pure range shift of the same problem is not churn.
    private static func identity(_ diagnostic: Diagnostic) -> String {
        "\(diagnostic.source)|\(diagnostic.code ?? "")|\(diagnostic.message)|\(diagnostic.severity)"
    }
}

private final class DiagnosticsBlockingBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

private struct DiagnosticsProfileFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
