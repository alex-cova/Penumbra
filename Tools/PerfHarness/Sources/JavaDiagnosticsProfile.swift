import Foundation
import EditorIntelligence
import JavaIntelligence
import LanguageSyntax

/// Error-highlighting parity harness: `survival`, `latency` and `typing`.
///
///   swift run -c release PerfHarness java-diagnostics survival synthetic [--lines N]
///   swift run -c release PerfHarness java-diagnostics survival <directory> [--lines N]
///   swift run -c release PerfHarness java-diagnostics latency synthetic [--lines N] [--samples N]
///   swift run -c release PerfHarness java-diagnostics latency <file> [--samples N]
///   swift run -c release PerfHarness java-diagnostics typing synthetic [--lines N]
///   swift run -c release PerfHarness java-diagnostics typing <file>
///
/// Survival: run inspections on valid text, inject `foo(` as the first statement of one
/// method (a half-typed edit that breaks the tree), re-run, and count baseline findings
/// outside the edited member whose identity (`source`, `code`, `message`, `severity`)
/// survives. A pure range shift is not churn. Phase 1 target: imports survive at 100%.
/// Latency: open simulation — time to first squiggle per source (syntax parse, inspection
/// pass, `javac` check when a JDK is available). Typing: a scripted half-typed burst, and
/// the idle-to-fresh-squiggle time after each keystroke. Inspections and syntax run
/// hermetically; the `javac` column is the cold CLI check and needs a JDK (skipped
/// otherwise). Warm-server checks are timed by `java-analysis-server`, not here.
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

    /// Open simulation: parse, inspection pass and `javac` check times for one file.
    /// The `javac` column needs a JDK; without one it is skipped, not failed.
    static func runLatency(pathOrSynthetic: String, lines: Int, samples: Int) throws {
        let (name, text) = try singleSource(pathOrSynthetic: pathOrSynthetic, lines: lines)
        let lineCount = text.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }

        var parses: [Double] = []
        for sample in 0...samples {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = JavaSyntaxParser().parse(text)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if sample > 0 { parses.append(elapsed) }
        }

        let passes = try DiagnosticsProbe.runAsync {
            let service = JavaInspectionService(
                index: JavaIndex(), enabledRules: DiagnosticsProbe.indexFreeRules, idleDelay: .milliseconds(1))
            var timings: [Double] = []
            for sample in 0...samples {
                let document = DiagnosticsProbe.document(text: text, url: DiagnosticsProbe.url(for: name), version: sample)
                let start = DispatchTime.now().uptimeNanoseconds
                await service.analyzeNow(document, force: true)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                if sample > 0 { timings.append(elapsed) }
            }
            return timings
        }

        var javacSummary = "skipped(no-jdk)"
        if let check = try timeJavacCheck(text: text, name: name) {
            javacSummary = "check_s=\(formatSeconds(check))"
        }
        print(
            "stage java_diagnostics_latency file=\(name) lines=\(lineCount) "
                + "syntax_s=\(formatSeconds(median(parses))) "
                + "inspection_s=\(formatSeconds(median(passes))) javac_\(javacSummary)"
        )
    }

    /// One cold CLI `javac` check of exactly this text (plain folder, temp project), or nil
    /// when no JDK is available. Single shot: a cold compile costs seconds by design.
    private static func timeJavacCheck(text: String, name: String) throws -> Double? {
        guard let jdk = JDKLocator().select(), jdk.javac != nil else { return nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf-javac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try DiagnosticsProbe.runAsync {
            let service = JavaCompilerDiagnosticsService(idleDelay: .zero)
            await service.configure(.init(
                kind: .plainFolder, jdk: jdk, projectRoot: root, workDirectory: root.appendingPathComponent("work")))
            let document = DiagnosticsProbe.document(text: text, url: DiagnosticsProbe.url(for: name), version: 0)
            let start = DispatchTime.now().uptimeNanoseconds
            _ = await service.freshDiagnostics(for: document)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }
    }

    private static func singleSource(pathOrSynthetic: String, lines: Int) throws -> (name: String, text: String) {
        if pathOrSynthetic == "synthetic" || pathOrSynthetic == "-" {
            return ("synthetic", syntheticWithUnusedImports(lines: lines))
        }
        return (pathOrSynthetic, try String(contentsOfFile: pathOrSynthetic, encoding: .utf8))
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    private static func formatSeconds(_ value: Double) -> String { String(format: "%.6f", value) }

    /// A scripted half-typed burst: type `foo(\n1);` one key at a time into the first method,
    /// and after each keystroke measure the idle-to-fresh-squiggle time (the idle
    /// `diagnostics(for:)` path with a zero delay, as Umbra configures it — the adapter
    /// debounce above it is a host constant). A cold CLI `javac` per keystroke would cost
    /// minutes, so `javac` is checked once on the final text when a JDK is available.
    static func runTyping(pathOrSynthetic: String, lines: Int) throws {
        let (name, text) = try singleSource(pathOrSynthetic: pathOrSynthetic, lines: lines)
        guard let tree = JavaSyntaxParser().parse(text),
            let member = DiagnosticsProbe.firstEditableMember(in: tree)
        else {
            throw DiagnosticsProfileFailure(message: "typing needs a file with one method body")
        }
        let keys = ["f", "o", "o", "(", "\n", "1", ")", ";"]
        let counter = DeliveryCounter()
        let timings = try DiagnosticsProbe.runAsync {
            let service = JavaInspectionService(
                index: JavaIndex(), enabledRules: DiagnosticsProbe.indexFreeRules, idleDelay: .zero)
            await service.setResultHandler { _, _ in counter.increment() }
            var bytes = Array(text.utf8)
            var caret = member.insertionByte
            await service.analyzeNow(DiagnosticsProbe.document(text: text, url: DiagnosticsProbe.url(for: name), version: 0), force: true)
            var timings: [Double] = []
            for (index, key) in keys.enumerated() {
                let insertion = Array(key.utf8)
                bytes.insert(contentsOf: insertion, at: caret)
                caret += insertion.count
                let edited = String(decoding: bytes, as: UTF8.self)
                let document = DiagnosticsProbe.document(
                    text: edited, url: DiagnosticsProbe.url(for: name), version: index + 1)
                let start = DispatchTime.now().uptimeNanoseconds
                _ = await service.diagnostics(for: document)
                // Same-hash refreshes never duplicate a pass, so deliveries map 1:1 onto
                // distinct texts in order: delivery index + 2 is this edit's fresh result.
                let deadline = Date().addingTimeInterval(30)
                while counter.count < index + 2, Date() < deadline {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            return timings
        }
        for (index, elapsed) in timings.enumerated() {
            print("stage java_diagnostics_typing file=\(name) edit=\(index) inspection_s=\(formatSeconds(elapsed))")
        }
        var javacSummary = "skipped(no-jdk)"
        let finalText = finalTextAfterTyping(text: text, memberInsertionByte: member.insertionByte)
        if let final = try timeJavacCheck(text: finalText, name: name) {
            javacSummary = "check_s=\(formatSeconds(final))"
        }
        print(
            "stage java_diagnostics_typing_total file=\(name) edits=\(timings.count) "
                + "inspection_median_s=\(formatSeconds(median(timings))) "
                + "inspection_worst_s=\(formatSeconds(timings.max() ?? 0)) javac_\(javacSummary)"
        )
    }

    private static func finalTextAfterTyping(text: String, memberInsertionByte: Int) -> String {
        var bytes = Array(text.utf8)
        bytes.insert(contentsOf: Array("foo(\n1);".utf8), at: memberInsertionByte)
        return String(decoding: bytes, as: UTF8.self)
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

/// Shared hermetic plumbing for the three modes: index-free inspection analysis, member
/// location, document building and a blocking bridge for the synchronous CLI entry.
private enum DiagnosticsProbe {
    /// Index-free rules only: an empty index cannot resolve `String`, so the two
    /// index-backed rules would report noise instead of measuring anything.
    static let indexFreeRules = Set(JavaInspectionRule.allCases).subtracting([.unresolvedType, .unresolvedImport])

    static func url(for sourceName: String) -> URL {
        sourceName == "synthetic"
            ? URL(fileURLWithPath: "/perf/JavaDiagnostics.java")
            : URL(fileURLWithPath: sourceName)
    }

    static func document(text: String, url: URL, version: Int) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: version, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    /// A forced inspection pass of exactly this text, hermetically (empty index).
    static func analyzeInspections(text: String, url: URL) throws -> [Diagnostic] {
        try runAsync {
            let service = JavaInspectionService(index: JavaIndex(), enabledRules: indexFreeRules, idleDelay: .milliseconds(1))
            let box = DiagnosticsBlockingBox<[Diagnostic]>()
            await service.setResultHandler { _, diagnostics in box.value = diagnostics }
            await service.analyzeNow(document(text: text, url: url, version: 0), force: true)
            guard let diagnostics = box.value else {
                throw DiagnosticsProfileFailure(message: "inspection pass produced no result")
            }
            return diagnostics
        }
    }

    /// The first method or constructor body: insertion goes right after its `{`,
    /// so the edit breaks exactly this member.
    static func firstEditableMember(in tree: JavaSyntaxTree) -> (insertionByte: Int, memberBytes: Range<Int>)? {
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

    static func runAsync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = DiagnosticsBlockingBox<Result<T, Error>>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.value!.get()
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
        let url = DiagnosticsProbe.url(for: sourceName)
        let baselineDiagnostics = try DiagnosticsProbe.analyzeInspections(text: text, url: url)
        baseline = baselineDiagnostics.count
        guard let tree = JavaSyntaxParser().parse(text),
            let member = DiagnosticsProbe.firstEditableMember(in: tree)
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
        let brokenIdentities = Set(try DiagnosticsProbe.analyzeInspections(text: broken, url: url).map(Self.identity))
        outside = outsideBaseline.count
        survived = outsideBaseline.filter { brokenIdentities.contains(Self.identity($0)) }.count
        let importBaseline = outsideBaseline.filter { $0.code == "unused-import" || $0.code == "duplicate-import" }
        importsOutside = importBaseline.count
        importsSurvived = importBaseline.filter { brokenIdentities.contains(Self.identity($0)) }.count
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

private final class DeliveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.lock(); stored += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return stored }
}

private struct DiagnosticsProfileFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
