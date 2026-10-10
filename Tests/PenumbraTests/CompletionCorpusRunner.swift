import EditorIntelligence
import Foundation
import XCTest

/// Shared completion-corpus loader and ratchet. A case marks the caret with `/*|*/` and states
/// expectations on `//! key: value` lines. `contains`, `top1` and `top5` are scored: a name in
/// `baseline.json` must keep passing. `excludes`, `excludes_top5` and `count` fail the case outright.
enum CompletionCorpusRunner {
    static let caret = "/*|*/"

    struct Case {
        let name: String
        let url: URL
        let text: String
        let caretUTF16Offset: Int
        let directives: [String: String]

        var invocationCount: Int { directives["invocation"].flatMap(Int.init) ?? 1 }

        /// Typing drives most completion: the popup opens on the character before the caret. An
        /// empty prefix after whitespace or `(` is an explicit Ctrl+Space.
        var trigger: RequestTrigger {
            if directives["trigger"] == "manual" { return .manual }
            let before = (text as NSString).substring(to: caretUTF16Offset)
            guard let last = before.last, last != " ", last != "\n", last != "(", last != "\t" else { return .manual }
            if before.hasSuffix("::") { return .keystroke(":") }
            return .keystroke(String(last))
        }

        func document(language: String) -> Document {
            let position = CompletionCorpusRunner.position(in: text, utf16Offset: caretUTF16Offset)
            return Document(
                url: url,
                displayName: url.lastPathComponent,
                contentSnapshot: TextSnapshot(version: 1, text: text),
                selection: Selection(range: TextRange(start: position, end: position)),
                cursor: Cursor(position: position),
                viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
                languageIdentifier: language
            )
        }

        func completionContext() -> CompletionContext {
            let end = caretUTF16Offset
            let start = end - (prefix as NSString).length
            let startPosition = CompletionCorpusRunner.position(in: text, utf16Offset: start)
            let endPosition = CompletionCorpusRunner.position(in: text, utf16Offset: end)
            return CompletionContext(
                document: document(language: url.pathExtension == "ts" ? "typescript" : url.pathExtension),
                cursor: Cursor(position: endPosition),
                trigger: trigger,
                prefix: prefix,
                range: TextRange(start: startPosition, end: endPosition),
                invocationCount: invocationCount
            )
        }

        var prefix: String {
            let ns = text as NSString
            var index = caretUTF16Offset
            while index > 0 {
                let character = ns.character(at: index - 1)
                let scalar = UnicodeScalar(character)
                let isIdentifier = scalar.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" } ?? false
                if !isIdentifier { break }
                index -= 1
            }
            return ns.substring(with: NSRange(location: index, length: caretUTF16Offset - index))
        }

        static func load(from directory: URL, extension ext: String) throws -> [Case] {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == ext }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return try files.map { try parse(url: $0) }
        }

        static func parse(url: URL) throws -> Case {
            let raw = try String(contentsOf: url, encoding: .utf8)
            guard let caretRange = raw.range(of: caret) else {
                throw NSError(
                    domain: "corpus", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) has no caret"]
                )
            }
            let offset = raw.utf16.distance(from: raw.utf16.startIndex, to: caretRange.lowerBound.samePosition(in: raw.utf16)!)
            return Case(
                name: url.deletingPathExtension().lastPathComponent,
                url: url,
                text: raw.replacingOccurrences(of: caret, with: ""),
                caretUTF16Offset: offset,
                directives: CompletionCorpusRunner.directives(in: raw)
            )
        }
    }

    struct Baseline: Codable, Equatable {
        var passing: [String]

        static func load(from url: URL) -> Baseline? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Baseline.self, from: data)
        }

        func save(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url)
        }
    }

    struct Result {
        let name: String
        var hardFailures: [String] = []
        var scoredFailures: [String] = []
        var scored: Set<String> = []
        var scoredPasses: Set<String> = []

        var passes: Bool { hardFailures.isEmpty && scoredFailures.isEmpty }
    }

    static func position(in text: String, utf16Offset: Int) -> TextPosition {
        let prefix = (text as NSString).substring(to: min(utf16Offset, (text as NSString).length))
        let lines = prefix.components(separatedBy: "\n")
        return TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: utf16Offset)
    }

    static func rank(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        DefaultRanker(recency: CompletionRecency()).rankSynchronously(items: items, prefix: prefix).map(\.item)
    }

    static func directives(in raw: String) -> [String: String] {
        var directives: [String: String] = [:]
        for line in raw.components(separatedBy: "\n") where line.hasPrefix("//! ") {
            let body = line.dropFirst(4)
            guard let colon = body.firstIndex(of: ":") else { continue }
            directives[String(body[..<colon]).trimmingCharacters(in: .whitespaces)] =
                String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return directives
    }

    static func list(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Label checks shared by every language. Java adds its own site and type checks on top.
    static func checkLabels(_ corpusCase: Case, ranked: [CompletionItem], into result: inout Result) {
        let labels = ranked.map(\.label)
        let labelSet = Set(labels)
        let directives = corpusCase.directives

        if let excludes = directives["excludes"] {
            for label in list(excludes) where labelSet.contains(label) {
                result.hardFailures.append("offers excluded \(label)")
            }
        }
        if let excludes = directives["excludes_top5"] {
            let top = Set(labels.prefix(5))
            for label in list(excludes) where top.contains(label) {
                result.hardFailures.append("excluded \(label) in top 5")
            }
        }
        if let count = directives["count"], let wanted = Int(count), labels.count != wanted {
            result.hardFailures.append("\(labels.count) items, expected \(wanted)")
        }
        if let contains = directives["contains"] {
            result.scored.insert("contains")
            let missing = list(contains).filter { !labelSet.contains($0) }
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
            let missing = list(top5).filter { !top.contains($0) }
            if missing.isEmpty { result.scoredPasses.insert("top5") }
            else { result.scoredFailures.append("top5 missing \(missing.joined(separator: ", "))") }
        }
    }

    /// A name that passed in `baseline` must still pass. `update` rewrites the baseline with the names that pass now.
    static func enforce(
        results: [Result],
        baseline: Baseline?,
        update: Bool,
        save: (Baseline) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if update {
            try save(Baseline(passing: results.filter(\.passes).map(\.name).sorted()))
            return
        }
        guard let baseline else { return }
        let passingNow = Set(results.filter(\.passes).map(\.name))
        for name in baseline.passing where !passingNow.contains(name) {
            let detail = results.first { $0.name == name }.map { ($0.hardFailures + $0.scoredFailures).joined(separator: "; ") } ?? "case missing"
            XCTFail("Ratchet: \(name) passed in baseline.json and now fails: \(detail)", file: file, line: line)
        }
    }
}
