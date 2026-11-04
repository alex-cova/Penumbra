import Foundation
@_spi(Benchmarks) import Penumbra
import PenumbraLanguages

/// F19: where one workspace-index parse (`TreeSitterLanguageParser.parse`) spends its time.
///
///   swift run -c release PerfHarness index-parse synthetic [--lines N] [--lang java] [--samples N]
///   swift run -c release PerfHarness index-parse path/to/File.java --lang java
@MainActor
enum IndexingParseProfile {
    static func run(pathOrSynthetic: String, language identifier: String, lines: Int, samples: Int) {
        let text = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-"
            ? EnterSessionProfile.syntheticJava(lines: lines)
            : ((try? String(contentsOfFile: pathOrSynthetic, encoding: .utf8)) ?? "")
        guard !text.isEmpty, let language = TreeSitterLanguage.bundled(forIdentifier: identifier) else {
            FileHandle.standardError.write("index-parse: no text or no grammar for \(identifier)\n".data(using: .utf8)!)
            return
        }
        var runs: [IndexingParseBenchmark.Breakdown] = []
        for _ in 0 ..< max(samples, 1) { runs.append(IndexingParseBenchmark.measure(language: language, text: text)) }
        func median(_ key: KeyPath<IndexingParseBenchmark.Breakdown, Double>) -> Double {
            let values = runs.map { $0[keyPath: key] }.sorted()
            return values[values.count / 2] * 1000
        }
        let last = runs[runs.count - 1]
        let total = median(\.fullParse) + median(\.symbols) + median(\.words) + median(\.imports)
        let line = String(
            format: "  %@ %d chars, %d symbols, %d distinct words: parser creation %.2f ms | full parse %.2f | symbols %.2f | words %.2f | imports %.2f | total %.2f ms | incremental reparse %.2f ms",
            identifier as NSString, text.utf16.count, last.symbolCount, last.wordCount,
            median(\.parserCreation), median(\.fullParse), median(\.symbols), median(\.words), median(\.imports), total, median(\.incrementalParse)
        )
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)

        // The whole pass after one typed character: from scratch (what every pass cost) and reusing
        // the document's previous tree (what a repeat pass costs now).
        var scratch: [Double] = []
        var reused: [Double] = []
        for _ in 0 ..< max(samples, 1) {
            let box = ResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                box.value = await IndexingParseBenchmark.measureIndexPass(
                    makeLanguage: { TreeSitterLanguage.bundled(forIdentifier: identifier)! }, text: text
                )
                semaphore.signal()
            }
            semaphore.wait()
            if let value = box.value {
                scratch.append(value.fromScratch)
                reused.append(value.incremental)
            }
        }
        scratch.sort()
        reused.sort()
        if !scratch.isEmpty {
            let pass = String(
                format: "  index pass after one typed character: from scratch %.2f ms, reusing the previous tree %.2f ms",
                scratch[scratch.count / 2] * 1000, reused[reused.count / 2] * 1000
            )
            FileHandle.standardError.write((pass + "\n").data(using: .utf8)!)
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: (fromScratch: Double, incremental: Double)?
}
