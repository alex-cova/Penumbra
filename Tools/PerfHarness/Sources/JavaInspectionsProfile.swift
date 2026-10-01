import Foundation
import EditorIntelligence
import JavaIntelligence

/// Release-mode cost of a full `JavaInspectionService` pass (parse, context, every rule,
/// suppression filter) over one file. The pass runs debounced and off the main thread, so this
/// is a throughput number, not a keystroke gate; what matters is that it stays linear in the file.
///
///   swift run -c release PerfHarness java-inspections synthetic --lines 20000
///   swift run -c release PerfHarness java-inspections /path/to/Big.java
enum JavaInspectionsProfile {
    static func run(pathOrSynthetic: String, lines: Int, samples: Int) throws {
        let isSynthetic = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-"
        let source = isSynthetic
            ? syntheticJava(lines: lines)
            : String(decoding: try Data(contentsOf: URL(fileURLWithPath: pathOrSynthetic)), as: UTF8.self)
        let lineCount = source.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
        let timings = try runBlocking { try await measure(source: source, samples: samples) }
        let sorted = timings.sorted()
        let median = sorted[sorted.count / 2]
        print("stage java_inspections lines=\(lineCount) count=\(sorted.count) median_s=\(format(median)) worst_s=\(format(sorted.last ?? 0))")
        print("stage java_inspections_per_1k_lines lines=\(lineCount) median_s=\(format(median / Double(max(1, lineCount)) * 1000))")
    }

    private static func measure(source: String, samples: Int) async throws -> [Double] {
        let url = URL(fileURLWithPath: "/perf/Perf.java")
        let service = JavaInspectionService(index: JavaIndex(), idleDelay: .milliseconds(1))
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            url: url, displayName: "Perf.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        var timings: [Double] = []
        var findings = 0
        service_loop: for index in 0 ..< samples + 1 {
            let start = DispatchTime.now().uptimeNanoseconds
            await service.analyzeNow(document, force: true)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if index > 0 { timings.append(elapsed) } // the first pass warms the parse cache
            if index == 0 { findings = await service.diagnostics(for: document).count }
            if timings.count >= samples { break service_loop }
        }
        FileHandle.standardError.write("java-inspections: \(findings) findings\n".data(using: .utf8)!)
        return timings
    }

    /// Methods that trip a handful of rules, so the pass reports findings instead of only walking.
    static func syntheticJava(lines target: Int) -> String {
        var out = ["package demo;", "", "import java.util.*;", ""]
        var classIndex = 0
        while out.count < target {
            out.append("public class Service\(classIndex) {")
            out.append("    private final Map<String, Integer> cache = new HashMap<>();")
            out.append("    int[] data = new int[4];")
            for method in 0 ..< 8 {
                out.append("")
                out.append("    public int compute\(method)(String key, String other, int limit, int[] copy) {")
                out.append("        int total = 0;")
                out.append("        for (int i = 0; i < limit; i++) {")
                out.append("            total += key.length() * i + \(method);")
                out.append("        }")
                out.append("        if (key == other) total++;")
                out.append("        if (data == copy) total--;")
                out.append("        String text = \"\" + total;")
                out.append("        int biggest = total > limit ? total : limit;")
                out.append("        return cache.getOrDefault(key, biggest + text.length());")
                out.append("    }")
            }
            out.append("}")
            out.append("")
            classIndex += 1
        }
        return out.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String { String(format: "%.6f", value) }

    private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = InspectionsBlockingBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }
}

private final class InspectionsBlockingBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}
