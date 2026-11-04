import Darwin
import EditorIntelligence
import Foundation
import LanguageSyntax
import SwiftIntelligence
import TypeScriptIntelligence

/// Cold index time and completion latency for the native Swift and TypeScript tiers.
///
///   swift run -c release PerfHarness swift-index synthetic [--files N]
///   swift run -c release PerfHarness swift-completion synthetic [--files N] [--lines N]
///   swift run -c release PerfHarness ts-index synthetic [--files N]
///   swift run -c release PerfHarness ts-completion synthetic [--files N] [--lines N]
///
/// Index rows are one cold `setRoot` plus resident memory. Completion rows are p50/p95 of
/// `provide` after a warmup, and one incremental reparse of a `--lines` file after a one-character edit.
enum LanguageIndexProfile {
    enum Language: String {
        case swift
        case typescript
    }

    static func run(language: Language, mode: Mode, pathOrSynthetic: String, files: Int, lines: Int) throws {
        try runBlocking {
            try await measure(language: language, mode: mode, pathOrSynthetic: pathOrSynthetic, files: files, lines: lines)
        }
    }

    enum Mode { case index, completion }

    private static func measure(
        language: Language, mode: Mode, pathOrSynthetic: String, files: Int, lines: Int
    ) async throws {
        let synthetic = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-\(language.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let root: URL
        if synthetic {
            root = scratch.appendingPathComponent("src", isDirectory: true)
            try writeSynthetic(language: language, count: files, in: root)
        } else {
            root = URL(fileURLWithPath: pathOrSynthetic)
        }
        note("=== \(language.rawValue) \(mode == .index ? "index" : "completion") (\(synthetic ? "synthetic \(files) files" : root.path)) ===")

        let before = residentBytes()
        let started = DispatchTime.now().uptimeNanoseconds
        let indexed: Int
        switch language {
        case .swift:
            let index = SwiftIndex()
            await index.setRoot(root)
            indexed = await index.fileCount
        case .typescript:
            let index = TypeScriptIndex()
            await index.setRoot(root)
            indexed = await index.fileCount
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        let after = residentBytes()
        let stage = language == .swift ? "swift_index" : "ts_index"
        print("stage \(stage) cold count=1 median_s=\(format(elapsed)) files=\(indexed) resident_bytes=\(after) delta_bytes=\(after &- before)")

        if synthetic {
            try await measureFileChange(language: language, root: root, files: files)
            await measureLookups(language: language, root: root, files: files)
            await measureParseCache(language: language)
        }
        guard mode == .completion else { return }
        try await measureCompletion(language: language, root: root, lines: lines)
    }

    private static func makeParseCache(languageIdentifier: String, maxEntries: Int) -> DocumentParseCache {
        let grammar = languageIdentifier == "swift" ? SwiftAnalysis.language : TypeScriptAnalysis.language
        return DocumentParseCache(languageIdentifier: languageIdentifier, language: grammar, maxEntries: maxEntries)
    }

    /// F27: the per-language parse cache under many open documents. The same 200 documents are asked
    /// for in the same order three times (what a re-analysis of every open tab does after a save):
    /// a least-recently-used cache smaller than that misses every time, so the cap decides whether
    /// the second and third passes cost a parse each or a string comparison.
    private static func measureParseCache(language: Language) async {
        let documents = 200
        let languageIdentifier = language.rawValue
        let ext = language == .swift ? "swift" : "ts"
        let body = (0..<300).map { language == .swift ? "let value\($0) = \($0) + 1" : "const value\($0) = \($0) + 1" }.joined(separator: "\n")
        for cap in [64, 256] {
            let cache = makeParseCache(languageIdentifier: languageIdentifier, maxEntries: cap)
            var passSeconds: [Double] = []
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                for index in 0..<documents {
                    let url = URL(fileURLWithPath: "/tmp/perf-cache/file\(index).\(ext)")
                    _ = await cache.tree(for: makeDocument(languageIdentifier: languageIdentifier, url: url, text: body + "\n// \(index)", version: 1))
                }
                passSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            let stats = await cache.statistics
            let total = stats.hits + stats.fullParses + stats.incremental
            let rate = total == 0 ? 0 : Double(stats.hits) / Double(total)
            print("stage \(language == .swift ? "swift" : "ts")_parse_cache cap=\(cap) documents=\(documents) hit_rate=\(String(format: "%.3f", rate)) full_parses=\(stats.fullParses) evictions=\(stats.evictions) pass1_s=\(format(passSeconds[0])) pass2_s=\(format(passSeconds[1])) pass3_s=\(format(passSeconds[2]))")
        }
    }

    /// F27: palette lookups (`symbols(matching:)`) and completion's `exports(matching:)` against a
    /// project of `files` files, for a query that matches at once, one that matches only the last
    /// file's type, and one that matches nothing. The scans stop at the limit, so the last two show
    /// how the cost grows with the project.
    private static func measureLookups(language: Language, root: URL, files: Int) async {
        let queries: [(label: String, text: String)] = [
            ("early", "Type1"), ("late", "Type\(files - 1)"), ("miss", "Zzqxv")
        ]
        let swiftIndex = SwiftIndex()
        let tsIndex = TypeScriptIndex()
        switch language {
        case .swift: await swiftIndex.setRoot(root)
        case .typescript: await tsIndex.setRoot(root)
        }
        for (label, query) in queries {
            for kind in ["symbols", "exports"] {
                var times: [Double] = []
                for sample in 0..<9 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    switch (language, kind) {
                    case (.swift, "symbols"): _ = await swiftIndex.symbols(matching: query, limit: 50)
                    case (.swift, _): _ = await swiftIndex.exports(matching: query, limit: 50)
                    case (.typescript, "symbols"): _ = await tsIndex.symbols(matching: query, limit: 50)
                    case (.typescript, _): _ = await tsIndex.exports(matching: query, limit: 50)
                    }
                    if sample > 0 { times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9) }
                }
                let distribution = LatencyDistributionReducer.reduce(times)
                let stage = language == .swift ? "swift_lookup" : "ts_lookup"
                print("stage \(stage) \(kind)_\(label) count=\(distribution.count) median_s=\(format(distribution.median)) p95_s=\(format(distribution.p95)) files=\(files)")
            }
        }
    }

    /// F09: what saving one file costs the index. Each sample rewrites one file of a synthetic
    /// project (a renamed class, so names, exports and palette symbols all change) and applies it;
    /// the time should not depend on how many other files the project has.
    private static func measureFileChange(language: Language, root: URL, files: Int) async throws {
        let samples = 8
        let ext = language == .swift ? "swift" : "ts"
        let url = root.appendingPathComponent("p0/Type0.\(ext)")
        let original = try String(contentsOf: url, encoding: .utf8)
        defer { try? original.write(to: url, atomically: true, encoding: .utf8) }
        var times: [Double] = []
        switch language {
        case .swift:
            let index = SwiftIndex()
            await index.setRoot(root)
            for sample in 0...samples {
                try original.replacingOccurrences(of: "Type0", with: "Type0Edit\(sample)").write(to: url, atomically: true, encoding: .utf8)
                let start = DispatchTime.now().uptimeNanoseconds
                await index.applyFileChanges([url])
                if sample > 0 { times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9) }
            }
        case .typescript:
            let index = TypeScriptIndex()
            await index.setRoot(root)
            for sample in 0...samples {
                try original.replacingOccurrences(of: "Type0", with: "Type0Edit\(sample)").write(to: url, atomically: true, encoding: .utf8)
                let start = DispatchTime.now().uptimeNanoseconds
                await index.applyFileChanges([url])
                if sample > 0 { times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9) }
            }
        }
        emit(stage: language == .swift ? "swift_index_file_changed" : "ts_index_file_changed", samples: times)
    }

    private static func measureCompletion(language: Language, root: URL, lines: Int) async throws {
        let samples = 8
        let source = completingSource(language: language, lines: lines)
        let url = root.appendingPathComponent(language == .swift ? "Complete.swift" : "complete.ts")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let document = makeDocument(language: language, url: url, text: source)

        switch language {
        case .swift:
            let index = SwiftIndex()
            await index.setRoot(root)
            await index.noteOpenDocument(url: url, text: source)
            let provider = SwiftCompletionProvider(index: index)
            let context = completionContext(document: document, prefix: "")
            _ = await provider.provide(context: context)
            var times: [Double] = []
            for _ in 0..<samples {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = await provider.provide(context: context)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            emit(stage: "swift_completion", samples: times)
            try await measureReparse(languageIdentifier: "swift", lines: lines)
        case .typescript:
            let index = TypeScriptIndex()
            await index.setRoot(root)
            let cache = TypeScriptAnalysis.makeCache()
            let provider = TypeScriptCompletionProvider(cache: cache, index: index)
            let context = completionContext(document: document, prefix: "")
            _ = await provider.provide(context: context)
            var times: [Double] = []
            for _ in 0..<samples {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = await provider.provide(context: context)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            emit(stage: "ts_completion", samples: times)
            try await measureReparse(languageIdentifier: "typescript", lines: lines)
        }
    }

    /// Full parse of a generated file, then one incremental reparse after changing a single character.
    private static func measureReparse(languageIdentifier: String, lines: Int) async throws {
        let language = languageIdentifier == "swift" ? SwiftAnalysis.language : TypeScriptAnalysis.language
        var body = (0..<lines).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reparse-\(languageIdentifier).\(languageIdentifier == "swift" ? "swift" : "ts")")
        let cache = DocumentParseCache(languageIdentifier: languageIdentifier, language: language)
        _ = await cache.tree(for: makeDocument(languageIdentifier: languageIdentifier, url: url, text: body, version: 1))
        body.replaceSubrange(body.startIndex...body.startIndex, with: " ")
        let start = DispatchTime.now().uptimeNanoseconds
        _ = await cache.tree(for: makeDocument(languageIdentifier: languageIdentifier, url: url, text: body, version: 2))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let stage = languageIdentifier == "swift" ? "swift_reparse" : "ts_reparse"
        print("stage \(stage) one_character count=1 median_s=\(format(elapsed)) lines=\(lines)")
    }

    private static func writeSynthetic(language: Language, count: Int, in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ext = language == .swift ? "swift" : "ts"
        for file in 0..<count {
            let url = root.appendingPathComponent("p\(file % 40)/Type\(file).\(ext)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text: String
            if language == .swift {
                text = """
                struct Type\(file) {
                    var value: Int
                    func doubled() -> Int { value * 2 }
                    func label() -> String { "Type\(file)" }
                }
                """
            } else {
                text = """
                export class Type\(file) {
                    value: number
                    doubled(): number { return this.value * 2 }
                    label(): string { return "Type\(file)" }
                }
                """
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func completingSource(language: Language, lines: Int) -> String {
        let filler = (0..<lines).map { "let filler\($0) = \($0)" }.joined(separator: "\n")
        if language == .swift {
            return """
            struct Box {
                var name: String
                func label() -> String { name }
            }
            \(filler)
            let box = Box(name: "a")
            let value = box.
            """
        }
        return """
        export class Box {
            name: string
            label(): string { return this.name }
        }
        \(filler)
        const box = new Box()
        const value = box.
        """
    }

    private static func makeDocument(language: Language, url: URL, text: String) -> Document {
        makeDocument(languageIdentifier: language.rawValue, url: url, text: text, version: 1)
    }

    private static func makeDocument(languageIdentifier: String, url: URL, text: String, version: Int) -> Document {
        let end = (text as NSString).length
        let position = TextPosition(line: text.components(separatedBy: "\n").count - 1, column: 0, utf16Offset: end)
        return Document(
            url: url,
            displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: version, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
            languageIdentifier: languageIdentifier
        )
    }

    private static func completionContext(document: Document, prefix: String) -> CompletionContext {
        let end = document.cursor.position
        return CompletionContext(
            document: document, cursor: document.cursor, trigger: .manual, prefix: prefix,
            range: TextRange(start: end, end: end)
        )
    }

    private static func emit(stage: String, samples: [Double]) {
        let distribution = LatencyDistributionReducer.reduce(samples)
        print("stage \(stage) provide count=\(distribution.count) median_s=\(format(distribution.median)) p95_s=\(format(distribution.p95)) worst_s=\(format(distribution.worst))")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write("\(text)\n".data(using: .utf8)!)
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    private static func runBlocking(_ body: @escaping @Sendable () async throws -> Void) throws {
        let box = BlockingBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await body()
                box.result = .success(())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        try box.result?.get()
    }
}

private final class BlockingBox: @unchecked Sendable {
    var result: Result<Void, Error>?
}
