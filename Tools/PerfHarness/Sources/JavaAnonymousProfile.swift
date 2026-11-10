import EditorIntelligence
import Foundation
@_spi(Benchmarks) import JavaIntelligence

/// Receiver typing through anonymous classes, `getClass()` and multi-catch, the sites of
/// docs/JAVA_RECEIVER_FIDELITY_FINAL_AUDIT.md: release latency per completion request (a fresh provider
/// each time, so every request parses and binds), the worst case of anonymous classes nested eight deep
/// in a 5,000-line file, and resident memory across edits that change an anonymous body (each edit is a
/// new synthetic identity, `$Anonymous<hash>`, so a cache keyed by it would grow with the edit history).
///
///   swift run -c release PerfHarness java-anonymous synthetic [--samples N] [--edits N]
enum JavaAnonymousProfile {
    static func run(samples: Int, edits: Int) throws {
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await measure(samples: samples, edits: edits) } catch { box.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
    }

    private final class Box: @unchecked Sendable { var error: Error? }

    private struct Site {
        let name: String
        let depth: Int
        let statement: String
    }

    private static let sites = [
        Site(name: "anonymous_member_local", depth: 1, statement: "Cell1 c = new Cell1(); c."),
        Site(name: "anonymous_member_field_argument", depth: 1, statement: "cells1.get(0)."),
        Site(name: "nested8_innermost_member", depth: 8, statement: "Cell8 c = new Cell8(); c."),
        Site(name: "nested8_outermost_field", depth: 8, statement: "cells1.get(0)."),
        Site(name: "array_get_class", depth: 0, statement: "names.getClass()."),
        Site(name: "multi_catch", depth: 0, statement: "try { run(); } catch (java.io.IOException | NumberFormatException e) { e."),
    ]

    /// `depth` anonymous classes, each with a member class `Cell<k>` and a field `List<Cell<k>>`, the
    /// statement in the innermost method; `filler` methods before it make the file large.
    private static func source(depth: Int, statement: String, filler: Int, edit: Int? = nil) -> (before: String, after: String) {
        var before = "package com.perf.app;\n\nimport java.util.*;\n\nclass Anonymous {\n"
        before += JavaCompletionProfile.filler(filler)
        before += "    void run() { }\n    void test(String[] names) {\n"
        var closing = ""
        for level in 1...max(depth, 1) where depth > 0 {
            let marker = edit.map { "int edited\($0)_\(level);" } ?? ""
            before += "        Object o\(level) = new Object() {\n"
            before += "            class Cell\(level) implements Comparable<Cell\(level)> { int v\(level); \(marker) public int compareTo(Cell\(level) other) { return 0; } }\n"
            before += "            List<Cell\(level)> cells\(level) = new ArrayList<>();\n"
            before += "            void m\(level)() {\n"
            closing = "            }\n        };\n" + closing
        }
        before += "                \(statement)"
        let tail = statement.hasPrefix("try") ? " }\n" : "\n"
        return (before, tail + closing + "    }\n}\n")
    }

    private static func request(_ provider: JavaCompletionProvider, before: String, after: String, url: URL, version: Int) async -> Double {
        let text = before + after
        let lines = before.components(separatedBy: "\n")
        let position = TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: (before as NSString).length)
        let document = Document(
            id: DocumentID(), url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: version, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        let context = makeCompletionContext(document: document, trigger: .keystroke("."))
        let start = DispatchTime.now().uptimeNanoseconds
        var count = 0
        for await update in provider.provideUpdates(context: context) { count = update.items.count }
        if count == 0 { FileHandle.standardError.write("  warning: no items for \(url.lastPathComponent)\n".data(using: .utf8)!) }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    private static func measure(samples: Int, edits: Int) async throws {
        let (index, directory, jdkVersion) = try await JavaCompletionProfile.prepareIndex(jars: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Anonymous.java")
        print("=== java anonymous / getClass / multi-catch receivers (JDK \(jdkVersion), samples=\(samples)) ===")
        for (label, filler) in [("small", 0), ("large_5k", 1_000)] {
            for site in sites {
                let (before, after) = source(depth: site.depth, statement: site.statement, filler: filler)
                var times: [Double] = []
                for iteration in 0..<(samples + 2) {
                    let elapsed = await request(JavaCompletionProvider(index: index), before: before, after: after, url: url, version: iteration)
                    if iteration >= 2 { times.append(elapsed) }
                }
                let distribution = LatencyDistributionReducer.reduce(times)
                print("stage java_anonymous_\(label) band=\(site.name) median_ms=\(ms(distribution.median)) p95_ms=\(ms(distribution.p95)) worst_ms=\(ms(distribution.worst))")
            }
        }
        // One provider across edits of the innermost anonymous body, as when typing in it.
        let provider = JavaCompletionProvider(index: index)
        var editTimes: [Double] = []
        var resident: [UInt64] = []
        for edit in 0..<edits {
            let (before, after) = source(depth: 8, statement: "cells1.get(0).", filler: 1_000, edit: edit)
            editTimes.append(await request(provider, before: before, after: after, url: url, version: edit))
            if edit == 9 || edit == edits - 1 { resident.append(Measurement.residentMemoryBytes()) }
        }
        let distribution = LatencyDistributionReducer.reduce(Array(editTimes.dropFirst(10)))
        print("stage java_anonymous_edits band=nested8_large_5k edits=\(edits) median_ms=\(ms(distribution.median)) p95_ms=\(ms(distribution.p95))")
        if resident.count == 2 {
            let growth = Double(Int64(resident[1]) - Int64(resident[0])) / 1_048_576
            print("detail java_anonymous_edits resident_after_10_mb=\(String(format: "%.1f", Double(resident[0]) / 1_048_576)) resident_after_\(edits)_mb=\(String(format: "%.1f", Double(resident[1]) / 1_048_576)) growth_mb=\(String(format: "%.1f", growth))")
        }
    }

    private static func ms(_ seconds: Double) -> String { String(format: "%.3f", seconds * 1_000) }
}
