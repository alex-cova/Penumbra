import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// Runs the golden completion corpus (`Fixtures/JavaCompletionCorpus/cases`) against the real JDK
/// plus the fixture project, and prints a scorecard. See `docs/JAVA_COMPLETION_BASELINE.md`.
///
/// Each case file marks the caret with `/*|*/` and states its expectations in `//! key: value`
/// lines. Hard checks (`site`, `receiver`, `receiverKind`, `expected`, `excludes`, `excludes_top5`,
/// `count`, `import`, `appliedImport`, `chooser`, `qualifiedInsert`) fail the test outright. Scored checks (`contains`, `top1`,
/// `top5`) are ratcheted: a case listed as passing in `baseline.json` must keep passing. A case
/// tagged `gap: Gn` is a known failure tied to a plan gap; it never fails the test, and the
/// scorecard reports it when it starts passing so the tag can be removed.
///
/// `UPDATE_JAVA_COMPLETION_BASELINE=1 swift test --filter JavaCompletionCorpusTests` rewrites the
/// baseline with the cases that pass now.
final class JavaCompletionCorpusTests: XCTestCase {
    static let indexTask = Task { try await CorpusIndex.build() }

    /// The shared index, or a skip. CI sets `UMBRA_REQUIRE_JDK=1` (Scripts/ci-java-tests.sh): a
    /// missing JDK is then a failure, because a silent skip is how this suite once ran nothing.
    static func sharedIndex() async throws -> CorpusIndex {
        do {
            return try await indexTask.value
        } catch is CorpusIndex.NoJDK {
            if ProcessInfo.processInfo.environment["UMBRA_REQUIRE_JDK"] == "1" {
                XCTFail("UMBRA_REQUIRE_JDK=1 but no JDK with ct.sym was found")
                throw CorpusIndex.NoJDK()
            }
            throw XCTSkip("No JDK with ct.sym found on this machine")
        }
    }

    func testCorpus() async throws {
        let corpus = try await Self.sharedIndex()
        var cases = try CompletionCorpusRunner.Case.load(from: corpus.casesDirectory, extension: "java")
        let only = ProcessInfo.processInfo.environment["JAVA_COMPLETION_CASE"]
        if let only { let names = only.split(separator: ",").map(String.init); cases = cases.filter { name in names.contains { name.name.hasPrefix($0) } } } else { XCTAssertGreaterThan(cases.count, 100) }

        var results: [CaseResult] = []
        for corpusCase in cases {
            results.append(await run(corpusCase, index: corpus.index))
        }

        let baseline = Baseline.load()
        let report = Scorecard(results: results, jdkVersion: corpus.jdkVersion)
        print(report.render(baseline: baseline))
        try? report.render(baseline: baseline).write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("java-completion-scorecard.txt"),
            atomically: true, encoding: .utf8
        )

        for result in results where !result.isKnownGap {
            for failure in result.hardFailures {
                XCTFail("\(result.name): \(failure)")
            }
        }
        if only != nil { return }
        if ProcessInfo.processInfo.environment["UPDATE_JAVA_COMPLETION_BASELINE"] == "1" {
            try Baseline(jdkVersion: corpus.jdkVersion, passing: results.filter(\.passes).map(\.name).sorted()).save()
        } else if let baseline, baseline.jdkVersion == corpus.jdkVersion {
            let passingNow = Set(results.filter(\.passes).map(\.name))
            for name in baseline.passing where !passingNow.contains(name) {
                let detail = results.first { $0.name == name }.map { ($0.hardFailures + $0.scoredFailures).joined(separator: "; ") } ?? "case missing"
                XCTFail("Ratchet: \(name) passed in baseline.json and now fails: \(detail)")
            }
        }
    }

    // MARK: - Running one case

    private func run(_ corpusCase: CorpusCase, index: JavaIndex) async -> CaseResult {
        let text = corpusCase.text
        let position = Self.position(in: text, utf16Offset: corpusCase.caretUTF16Offset)
        let document = Document(
            id: DocumentID(), url: corpusCase.url, displayName: corpusCase.url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        let context = makeCompletionContext(
            document: document, trigger: corpusCase.trigger, invocationCount: corpusCase.invocationCount, mode: .basic
        )
        // Umbra keeps the open document's classes in the overlay (`JavaOverlayService`), from the
        // last parse that still had them; the repaired text stands in for that parse here.
        let parseable = JavaCompletionProvider.repairedText(text, insertingDummyAt: corpusCase.caretUTF16Offset)
        let ownStubs = JavaSourceStubBuilder.build(source: parseable, url: corpusCase.url).classes
        await index.setOverlay(Dictionary(ownStubs.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first }))
        let provider = JavaCompletionProvider(index: index)
        let clock = ContinuousClock()
        let start = clock.now
        let items = await provider.provide(context: context)
        let elapsed = clock.now - start
        let diagnosis = await provider.diagnose(context: context)
        if ProcessInfo.processInfo.environment["JAVA_COMPLETION_DEBUG"] == "1" {
            print("DEBUGTYPE \(corpusCase.name): \(diagnosis?.receiverType.map { String(describing: $0) } ?? "nil")")
        }
        let ranked = DefaultRanker(recency: CompletionRecency()).rankSynchronously(items: items, prefix: context.prefix).map(\.item)
        var result = CaseResult(
            name: corpusCase.name, gap: corpusCase.directives["gap"],
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            topTen: ranked.prefix(10).map { "\($0.label)\($0.labelDetail ?? "") [\(String(format: "%.2f", $0.priority))]" }
        )
        Self.check(corpusCase, ranked: ranked, diagnosis: diagnosis, into: &result)
        return result
    }

    private static func check(_ corpusCase: CorpusCase, ranked: [CompletionItem], diagnosis: JavaCompletionProvider.Diagnosis?, into result: inout CaseResult) {
        let labels = ranked.map(\.label)
        let labelSet = Set(labels)
        let directives = corpusCase.directives

        if let site = directives["site"] {
            let actual = diagnosis.map { String(describing: $0.site).components(separatedBy: "(").first ?? "" } ?? "nil"
            if actual != site { result.hardFailures.append("site \(actual), expected \(site)") }
        }
        if let receiver = directives["receiver"] {
            let actual = diagnosis?.receiverType.map(Self.erasedName) ?? "nil"
            if actual != receiver { result.hardFailures.append("receiver \(actual), expected \(receiver)") }
        }
        if let kind = directives["receiverKind"] {
            let actual = diagnosis.map { $0.receiverIsTypeReference ? "type" : "value" } ?? "nil"
            if actual != kind { result.hardFailures.append("receiverKind \(actual), expected \(kind)") }
        }
        if let expected = directives["expected"] {
            let actual = (diagnosis?.expected ?? []).map(Self.describe)
            for wanted in Self.list(expected) where !actual.contains(wanted) {
                result.hardFailures.append("expected type \(wanted) not in \(actual)")
            }
        }
        if let excludes = directives["excludes"] {
            for label in Self.list(excludes) where labelSet.contains(label) {
                result.hardFailures.append("offers excluded \(label)")
            }
        }
        if let excludes = directives["excludes_top5"] {
            let top = Set(labels.prefix(5))
            for label in Self.list(excludes) where top.contains(label) {
                result.hardFailures.append("excluded \(label) in top 5")
            }
        }
        if let count = directives["count"], let wanted = Int(count), labels.count != wanted {
            result.hardFailures.append("\(labels.count) items, expected \(wanted)")
        }
        if let wantedImport = directives["import"] {
            if let first = ranked.first {
                let edits = first.additionalEdits.map(\.replacement).joined()
                if wantedImport == "none" {
                    if !edits.isEmpty { result.hardFailures.append("top item adds \(edits.trimmingCharacters(in: .whitespacesAndNewlines))") }
                } else if !edits.contains("import \(wantedImport);") {
                    result.hardFailures.append("top item does not import \(wantedImport) (edits: \(edits.trimmingCharacters(in: .whitespacesAndNewlines)))")
                }
            } else {
                result.hardFailures.append("no items to check import")
            }
        }
        if let spec = directives["chooser"] {
            let parts = spec.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                let expected = parts[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                let actual = ranked.filter { $0.label == parts[0] }.map { $0.labelDetail ?? "" }
                if actual != expected {
                    result.hardFailures.append("chooser \(parts[0]) is \(actual), expected \(expected)")
                }
            }
        }
        if let wantedImport = directives["appliedImport"] {
            let label = directives["applies"]
            let wantSnippet = directives["applyKind"] == "snippet"
            let item = label.flatMap { name in
                ranked.first { $0.label == name && (!wantSnippet || $0.isSnippet) }
            }
            if let item {
                let edits = item.additionalEdits.map(\.replacement).joined()
                if wantedImport == "none" {
                    if edits.contains("import ") { result.hardFailures.append("applied item adds \(edits.trimmingCharacters(in: .whitespacesAndNewlines))") }
                } else if !edits.contains("import \(wantedImport);") {
                    result.hardFailures.append("applied item does not import \(wantedImport) (edits: \(edits.trimmingCharacters(in: .whitespacesAndNewlines)))")
                }
            } else {
                result.hardFailures.append("no applied item to check import")
            }
        }
        if let label = directives["applies"] {
            // `applies: if` + `yields: if (flag) {`: accept the item and check the edited text.
            // `applyKind: snippet` picks the template when a member has the same label (`format`).
            let wantSnippet = directives["applyKind"] == "snippet"
            if let item = ranked.first(where: { $0.label == label && (!wantSnippet || $0.isSnippet) }) {
                // Directive lines are left out, or `yields:` would always find itself.
                let body = Self.apply(item, to: corpusCase.text)
                    .components(separatedBy: "\n").filter { !$0.hasPrefix("//!") }.joined(separator: "\n")
                let wanted = (directives["yields"] ?? "").replacingOccurrences(of: "\\n", with: "\n")
                if wanted.isEmpty || !body.contains(wanted) {
                    result.hardFailures.append("applying \(label) does not yield \(wanted.debugDescription) in:\n\(body)")
                }
            } else {
                result.hardFailures.append("no item \(label) to apply")
            }
        }
        if let shows = directives["shows"] {
            // `shows: get -> User | -` : the item's type column and origin (`-` for none).
            for entry in shows.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let parts = entry.components(separatedBy: "->")
                guard parts.count == 2 else { continue }
                let label = parts[0].trimmingCharacters(in: .whitespaces)
                let columns = parts[1].components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let item = ranked.first(where: { $0.label == label }) else {
                    result.hardFailures.append("no item \(label) to present")
                    continue
                }
                let actual = "\(item.detail ?? "-") | \(item.origin ?? "-")"
                if actual != columns.joined(separator: " | ") {
                    result.hardFailures.append("\(label) shows \(actual), expected \(columns.joined(separator: " | "))")
                }
            }
        }
        if let qualified = directives["qualifiedInsert"], !ranked.contains(where: { $0.insertText == qualified }) {
            result.hardFailures.append("no item inserts \(qualified)")
        }

        if let contains = directives["contains"] {
            result.scored.insert("contains")
            let missing = Self.list(contains).filter { !labelSet.contains($0) }
            if !missing.isEmpty { result.scoredFailures.append("missing \(missing.joined(separator: ", "))") }
            else { result.scoredPasses.insert("contains") }
        }
        if let top1 = directives["top1"] {
            result.scored.insert("top1")
            if labels.first == top1 { result.scoredPasses.insert("top1") }
            else { result.scoredFailures.append("top1 \(labels.first ?? "nil"), expected \(top1)") }
        }
        if let top5 = directives["top5"] {
            result.scored.insert("top5")
            let top = Set(labels.prefix(5))
            let missing = Self.list(top5).filter { !top.contains($0) }
            if missing.isEmpty { result.scoredPasses.insert("top5") }
            else { result.scoredFailures.append("top5 missing \(missing.joined(separator: ", "))") }
        }
    }

    // MARK: - Helpers

    /// The document after accepting `item` the way the controller does: a snippet expands to its
    /// placeholder defaults, then that text and the additional edits (all ranges refer to the
    /// original text) are applied back to front.
    static func apply(_ item: CompletionItem, to text: String) -> String {
        let insert = item.isSnippet
            ? SnippetEngine().expand(body: item.insertText, context: SnippetExpansionContext()).text
            : item.insertText
        var edits = [(item.range.start.utf16Offset, item.range.end.utf16Offset, insert)]
        edits += item.additionalEdits.map { ($0.range.start.utf16Offset, $0.range.end.utf16Offset, $0.replacement) }
        let result = NSMutableString(string: text)
        for (start, end, replacement) in edits.sorted(by: { $0.0 > $1.0 }) {
            result.replaceCharacters(in: NSRange(location: start, length: end - start), with: replacement)
        }
        return result as String
    }

    static func list(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func erasedName(_ type: JavaTypeRef) -> String {
        switch type {
        case .classType(let name, _, _): return name
        case .array: return "array"
        case .primitive(let primitive): return primitive.rawValue
        case .typeVariable(let name): return "typeVariable \(name)"
        case .unresolved(let name, _): return "unresolved \(name)"
        case .void: return "void"
        case .wildcard: return "?"
        }
    }

    static func describe(_ type: JavaTypeRef) -> String {
        switch type {
        case .classType(let name, let arguments, _):
            guard !arguments.isEmpty else { return name }
            return "\(name)<\(arguments.map(describe).joined(separator: ","))>"
        case .array(let element): return "\(describe(element))[]"
        case .primitive(let primitive): return primitive.rawValue
        case .typeVariable(let name): return name
        case .unresolved(let name, _): return "?\(name)"
        case .void: return "void"
        case .wildcard(let bound): return describe(bound)
        }
    }

    private static func describe(_ argument: JavaTypeArgument) -> String {
        switch argument {
        case .type(let type): return describe(type)
        case .wildcard(let bound): return describe(bound)
        }
    }

    private static func describe(_ bound: JavaWildcardBound?) -> String {
        switch bound {
        case .none: return "?"
        case .extends(let type): return "? extends \(describe(type))"
        case .superBound(let type): return "? super \(describe(type))"
        }
    }

    private static func position(in text: String, utf16Offset: Int) -> TextPosition {
        let prefix = (text as NSString).substring(to: utf16Offset)
        let lines = prefix.components(separatedBy: "\n")
        return TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: utf16Offset)
    }
}

// MARK: - Corpus

/// The shared index: the JDK's `ct.sym` plus the fixture project's sources, built once per run.
struct CorpusIndex: Sendable {
    struct NoJDK: Error {}

    let index: JavaIndex
    let casesDirectory: URL
    let jdkVersion: Int

    static var directory: URL {
        guard let resourceURL = Bundle.module.resourceURL else { fatalError("PenumbraTests bundle has no resourceURL") }
        for candidate in [resourceURL.appendingPathComponent("JavaCompletionCorpus"), resourceURL.appendingPathComponent("Fixtures/JavaCompletionCorpus")]
            where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("cases").path) {
            return candidate
        }
        fatalError("Could not locate JavaCompletionCorpus in test bundle at \(resourceURL)")
    }

    static func build() async throws -> CorpusIndex {
        guard let found = TestJDK.discovered, let installation = ReleaseFileParser.parse(found.home), installation.hasCtSym else {
            throw NoJDK()
        }
        let temporary = FileManager.default.temporaryDirectory
        let jdkShard = temporary.appendingPathComponent("corpus-jdk-\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(try JDKCtSymRoot(installation: installation).readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard)

        var projectStubs: [JavaClassStub] = []
        let projectDirectory = directory.appendingPathComponent("project")
        let enumerator = FileManager.default.enumerator(at: projectDirectory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "java" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            projectStubs += JavaSourceStubBuilder.build(source: source, url: url).classes
        }
        let projectShard = temporary.appendingPathComponent("corpus-project-\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(projectStubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: projectShard)

        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: try JavaIndexShardReader(url: projectShard)),
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard))
        ])
        return CorpusIndex(index: index, casesDirectory: directory.appendingPathComponent("cases"), jdkVersion: installation.featureVersion)
    }
}

private typealias CorpusCase = CompletionCorpusRunner.Case

private struct CaseResult {
    let name: String
    let gap: String?
    let seconds: Double
    let topTen: [String]
    var hardFailures: [String] = []
    var scoredFailures: [String] = []
    var scored: Set<String> = []
    var scoredPasses: Set<String> = []

    init(name: String, gap: String?, seconds: Double, topTen: [String]) {
        self.name = name
        self.gap = gap
        self.seconds = seconds
        self.topTen = topTen
    }

    var isKnownGap: Bool { gap != nil }
    var passes: Bool { hardFailures.isEmpty && scoredFailures.isEmpty }
}

private struct Baseline: Codable {
    let jdkVersion: Int
    let passing: [String]

    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/JavaCompletionCorpus/baseline.json")
    }

    static func load() -> Baseline? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Baseline.self, from: data)
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url)
    }
}

private struct Scorecard {
    let results: [CaseResult]
    let jdkVersion: Int

    func render(baseline: Baseline?) -> String {
        func count(_ check: String) -> (Int, Int) {
            let relevant = results.filter { $0.scored.contains(check) }
            return (relevant.filter { $0.scoredPasses.contains(check) }.count, relevant.count)
        }
        func percent(_ pair: (Int, Int)) -> String {
            pair.1 == 0 ? "n/a" : "\(Int((Double(pair.0) / Double(pair.1) * 100).rounded()))% (\(pair.0)/\(pair.1))"
        }
        let hardClean = results.filter { $0.hardFailures.isEmpty }.count
        let passing = results.filter(\.passes).count
        let latencies = results.map(\.seconds).sorted()
        func quantile(_ q: Double) -> String {
            guard !latencies.isEmpty else { return "n/a" }
            let value = latencies[min(latencies.count - 1, Int(Double(latencies.count - 1) * q))]
            return String(format: "%.0f ms", value * 1000)
        }
        var lines = [
            "Java completion corpus (JDK \(jdkVersion))",
            "cases \(results.count) | passing \(passing) | hard-clean \(hardClean) | known gaps \(results.filter(\.isKnownGap).count)",
            "contains \(percent(count("contains"))) | top1 \(percent(count("top1"))) | top5 \(percent(count("top5")))",
            "latency p50 \(quantile(0.5)) | p95 \(quantile(0.95)) | max \(quantile(1)) (debug build, informational)"
        ]
        let slowest = results.sorted { $0.seconds > $1.seconds }.prefix(5)
        lines.append("slowest: " + slowest.map { "\($0.name) \(String(format: "%.0f", $0.seconds * 1000)) ms" }.joined(separator: ", "))
        let baselinePassing = Set(baseline?.passing ?? [])
        for result in results where !result.passes {
            let tag = result.gap.map { " [gap \($0)]" } ?? ""
            lines.append("FAIL \(result.name)\(tag): \((result.hardFailures + result.scoredFailures).joined(separator: "; "))")
            lines.append("     top: \(result.topTen.joined(separator: ", "))")
        }
        for result in results where result.passes && result.isKnownGap {
            lines.append("UNEXPECTED PASS \(result.name) [gap \(result.gap ?? "")]: remove the gap tag")
        }
        for result in results where result.passes && baseline != nil && !baselinePassing.contains(result.name) {
            lines.append("NEW PASS \(result.name): run with UPDATE_JAVA_COMPLETION_BASELINE=1 to ratchet")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Through the engine

/// The corpus again, through the path the editor takes: `CompletionEngine` with the providers
/// Umbra registers (`IDEIntelligenceServices`: Symbol, Word, Snippet, then the language's own).
/// `JavaCompletionCorpusTests` calls the provider directly, so it cannot see the engine dropping
/// items (the merge keeps only items whose `source` is a primary provider's `name`).
final class JavaCompletionEnginePipelineTests: XCTestCase {
    /// Runs one case both ways: the provider alone, and the engine.
    private func run(_ corpusCase: CorpusCase, corpus: CorpusIndex) async throws -> (name: String, provider: [CompletionItem], engine: [CompletionItem]) {
        let context = corpusCase.completionContext()
        let parseable = JavaCompletionProvider.repairedText(corpusCase.text, insertingDummyAt: corpusCase.caretUTF16Offset)
        let ownStubs = JavaSourceStubBuilder.build(source: parseable, url: corpusCase.url).classes
        await corpus.index.setOverlay(Dictionary(ownStubs.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first }))
        let provider = JavaCompletionProvider(index: corpus.index)
        let symbols = SymbolIndex()
        let engine = CompletionEngine(
            providers: [
                SymbolCompletionProvider(index: symbols), WordCompletionProvider(index: symbols),
                SnippetCompletionProvider(), provider
            ],
            debounceInterval: 0
        )
        return (corpusCase.name, await provider.provide(context: context), try await engine.complete(context: context))
    }

    private func loadCases(_ corpus: CorpusIndex) throws -> [CorpusCase] {
        var cases = try CompletionCorpusRunner.Case.load(from: corpus.casesDirectory, extension: "java")
        if let only = ProcessInfo.processInfo.environment["JAVA_COMPLETION_CASE"] {
            let names = only.split(separator: ",").map(String.init)
            cases = cases.filter { item in names.contains { item.name.hasPrefix($0) } }
        }
        return cases
    }

    /// The engine filters on `item.source == provider.name`, so an item with any other spelling
    /// never reaches the popup. Command-section items are exempt: they are layered over the list.
    func testEveryJavaItemCarriesTheProviderName() async throws {
        let corpus = try await JavaCompletionCorpusTests.sharedIndex()
        var offenders: [String: Set<String>] = [:]
        for corpusCase in try loadCases(corpus) {
            let result = try await run(corpusCase, corpus: corpus)
            for item in result.provider where item.source != "Java" && item.section != .commands {
                offenders["\(item.source)", default: []].insert("\(item.label) (\(result.name))")
            }
        }
        for (source, labels) in offenders.sorted(by: { $0.key < $1.key }) {
            XCTFail("items with source \"\(source)\" are dropped by CompletionEngine, e.g. \(labels.sorted().prefix(5).joined(separator: ", ")) (\(labels.count) total)")
        }
    }

    /// Whatever the provider offers for a `contains:` expectation must survive the engine.
    func testEngineKeepsWhatTheCorpusExpects() async throws {
        let corpus = try await JavaCompletionCorpusTests.sharedIndex()
        var lost: [String] = []
        for corpusCase in try loadCases(corpus) {
            guard let contains = corpusCase.directives["contains"] else { continue }
            let result = try await run(corpusCase, corpus: corpus)
            let offered = Set(result.provider.map(\.label))
            let kept = Set(result.engine.map(\.label))
            let missing = JavaCompletionCorpusTests.list(contains).filter { offered.contains($0) && !kept.contains($0) }
            if !missing.isEmpty { lost.append("\(result.name): \(missing.joined(separator: ", "))") }
        }
        XCTAssertTrue(lost.isEmpty, "the engine dropped items the provider offered:\n\(lost.joined(separator: "\n"))")
    }

    /// The fast update must reach the stream while the slow phase is still running. The slow phase
    /// is held on a latch: if the first update only arrived after it, this would never get past
    /// the first `await` and the timeout would fail the test, with no clock involved in passing.
    func testFastUpdateIsPublishedBeforeTheSlowPhaseRuns() async throws {
        let corpus = try await JavaCompletionCorpusTests.sharedIndex()
        let text = "package com.acme.cases;\nclass LatchProbe {\n    void test(String name) {\n        na\n    }\n}\n"
        let caret = (text as NSString).range(of: "na\n").location + 2
        let url = URL(fileURLWithPath: "/virtual/LatchProbe.java")
        let corpusCase = CorpusCase(name: "LatchProbe", url: url, text: text, caretUTF16Offset: caret, directives: [:])
        await corpus.index.setOverlay([:])
        let provider = JavaCompletionProvider(index: corpus.index)
        let latch = Latch()
        await provider.setSlowPhaseHook { await latch.wait() }

        let stream = provider.provideUpdates(context: corpusCase.completionContext())
        let collector = UpdateCollector()
        let reader = Task { for await update in stream { await collector.add(update) } }

        // Only a failure waits out the deadline; passing means the update arrived with the latch closed.
        let deadline = ContinuousClock.now + .seconds(20)
        while await collector.updates.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let earlyUpdates = await collector.updates
        let early = try XCTUnwrap(earlyUpdates.first, "no update before the slow phase was released")
        XCTAssertFalse(early.isFinished)
        XCTAssertTrue(early.items.contains { $0.label == "name" }, "the fast update should carry the local")

        await latch.open()
        await reader.value
        let allUpdates = await collector.updates
        let final = try XCTUnwrap(allUpdates.last)
        XCTAssertTrue(final.isFinished)
        XCTAssertTrue(Set(early.items.map(\.label)).isSubset(of: Set(final.items.map(\.label))), "the final list keeps everything already shown")
    }

    /// A request that is superseded while its slow phase is pending must not run that phase.
    func testSupersededRequestSkipsItsSlowPhase() async throws {
        let corpus = try await JavaCompletionCorpusTests.sharedIndex()
        let text = "package com.acme.cases;\nclass CancelProbe {\n    void test(String name) {\n        na\n    }\n}\n"
        let caret = (text as NSString).range(of: "na\n").location + 2
        let corpusCase = CorpusCase(
            name: "CancelProbe", url: URL(fileURLWithPath: "/virtual/CancelProbe.java"), text: text, caretUTF16Offset: caret, directives: [:]
        )
        await corpus.index.setOverlay([:])
        let provider = JavaCompletionProvider(index: corpus.index)
        let latch = Latch()
        await provider.setSlowPhaseHook { await latch.wait() }

        let stream = provider.provideUpdates(context: corpusCase.completionContext())
        let collector = UpdateCollector()
        let reader = Task { for await update in stream { await collector.add(update) } }
        let deadline = ContinuousClock.now + .seconds(20)
        while await collector.updates.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The consumer goes away (a newer keystroke): the stream terminates and cancels the request.
        reader.cancel()
        await reader.value
        await latch.open()

        var skipped = 0
        var ran = 0
        while skipped + ran == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            skipped = await provider.slowPhaseSkipCount
            ran = await provider.slowPhaseRunCount
        }
        XCTAssertEqual(ran, 0, "the slow phase of a superseded request ran")
        XCTAssertEqual(skipped, 1)
    }
}

private actor UpdateCollector {
    private(set) var updates: [CompletionUpdate] = []
    func add(_ update: CompletionUpdate) { updates.append(update) }
}

private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
