import EditorIntelligence
import Foundation
import SwiftIntelligence
import TypeScriptIntelligence
import XCTest

/// Swift and TypeScript completion corpora. Each case is one file with `/*|*/` and `//!` directives.
/// A name in `baseline.json` has to keep passing. `UPDATE_SWIFT_COMPLETION_BASELINE=1` or
/// `UPDATE_TS_COMPLETION_BASELINE=1` rewrites that language's baseline.
final class NativeCompletionCorpusTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    func testSwiftCorpus() async throws {
        try await run(
            casesDirectory: fixtureRoot(named: "SwiftCorpus").appendingPathComponent("cases"),
            baselineURL: fixtureRoot(named: "SwiftCorpus").appendingPathComponent("baseline.json"),
            language: "swift",
            fileExtension: "swift",
            updateEnvironment: "UPDATE_SWIFT_COMPLETION_BASELINE"
        )
    }

    func testTypeScriptCorpus() async throws {
        try await run(
            casesDirectory: fixtureRoot(named: "TypeScriptCorpus").appendingPathComponent("cases"),
            baselineURL: fixtureRoot(named: "TypeScriptCorpus").appendingPathComponent("baseline.json"),
            language: "typescript",
            fileExtension: "ts",
            updateEnvironment: "UPDATE_TS_COMPLETION_BASELINE"
        )
    }

    private func run(
        casesDirectory: URL,
        baselineURL: URL,
        language: String,
        fileExtension: String,
        updateEnvironment: String
    ) async throws {
        let cases = try CompletionCorpusRunner.Case.load(from: casesDirectory, extension: fileExtension)
        XCTAssertFalse(cases.isEmpty)
        var results: [CompletionCorpusRunner.Result] = []
        for corpusCase in cases {
            results.append(await complete(corpusCase, language: language, fileExtension: fileExtension))
        }
        for result in results {
            for failure in result.hardFailures + result.scoredFailures {
                XCTFail("\(result.name): \(failure)")
            }
        }
        try CompletionCorpusRunner.enforce(
            results: results,
            baseline: CompletionCorpusRunner.Baseline.load(from: baselineURL),
            update: ProcessInfo.processInfo.environment[updateEnvironment] == "1",
            save: { try $0.save(to: baselineURL) }
        )
    }

    private func complete(
        _ corpusCase: CompletionCorpusRunner.Case, language: String, fileExtension: String
    ) async -> CompletionCorpusRunner.Result {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Case.\(fileExtension)")
        try? corpusCase.text.write(to: url, atomically: true, encoding: .utf8)
        let placed = CompletionCorpusRunner.Case(
            name: corpusCase.name, url: url, text: corpusCase.text,
            caretUTF16Offset: corpusCase.caretUTF16Offset, directives: corpusCase.directives
        )
        let context = placed.completionContext()
        let items: [CompletionItem]
        if language == "swift" {
            let index = SwiftIndex()
            await index.setRoot(root)
            await index.noteOpenDocument(url: url, text: placed.text)
            items = await SwiftCompletionProvider(index: index).provide(context: context)
        } else {
            let index = TypeScriptIndex()
            await index.setRoot(root)
            let cache = TypeScriptAnalysis.makeCache()
            items = await TypeScriptCompletionProvider(cache: cache, index: index).provide(context: context)
        }
        let ranked = CompletionCorpusRunner.rank(items, prefix: placed.prefix)
        var result = CompletionCorpusRunner.Result(name: placed.name)
        CompletionCorpusRunner.checkLabels(placed, ranked: ranked, into: &result)
        if !result.passes {
            result.hardFailures.append("top: \(ranked.prefix(8).map(\.label).joined(separator: ", "))")
        }
        return result
    }

    private func fixtureRoot(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }
}
