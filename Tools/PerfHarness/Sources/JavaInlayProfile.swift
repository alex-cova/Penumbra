import EditorIntelligence
import Foundation
import JavaIntelligence

enum JavaInlayProfile {
    static func run(lines: Int, samples: Int) {
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await measure(lines: lines, samples: samples)
            finished.signal()
        }
        finished.wait()
    }

    private static func measure(lines: Int, samples: Int) async {
        let actualLines = max(lines, 128)
        var rows = ["class Example {", ""]
        for row in 2..<(actualLines - 1) {
            rows.append("    int method\(row)() { var result = Library.limit(10, 20); return result; }")
        }
        rows.append("}")
        let source = rows.joined(separator: "\n")
        let map = SourceTextMap(source)
        let middle = actualLines / 2
        guard let startByte = map.byteOffset(line: middle, utf8Column: 0),
              let endByte = map.byteOffset(line: middle + 54, utf8Column: 0) else { return }
        let range = map.range(bytes: startByte..<endByte)
        let document = Document(
            url: URL(fileURLWithPath: "/tmp/Example.java"), displayName: "Example.java",
            contentSnapshot: TextSnapshot(version: 1, text: source), selection: Selection(range: range),
            cursor: Cursor(position: range.start), viewport: Viewport(x: 0, y: 0, width: 1200, height: 900),
            languageIdentifier: "java"
        )
        let index = JavaIndex()
        let library = "class Library { static int limit(int count, int fallback) { return count; } }"
        if let tree = JavaSyntaxParser().parse(library) {
            let stubs = JavaSourceStubBuilder.build(tree: tree, url: URL(fileURLWithPath: "/tmp/Library.java")).classes
            await index.setOverlay(Dictionary(uniqueKeysWithValues: stubs.map { ($0.qualifiedName, $0) }))
        }
        let provider = JavaInlayHintProvider(
            index: index, indexPaths: JavaIndexPaths(root: FileManager.default.temporaryDirectory)
        )
        await provider.setOptions(JavaInlayHintOptions(parameterNames: true, variableTypes: true))
        var times: [Double] = []
        var hintCount = 0
        for iteration in 0...max(1, samples) {
            let start = DispatchTime.now().uptimeNanoseconds
            hintCount = await provider.inlayHints(for: document, in: range).count
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            if iteration == 0 {
                ResultLog.row("java_inlay_cold", file: "synthetic-\(actualLines)", sizeBytes: UInt64(source.utf8.count),
                              seconds: seconds, extra: "samples=1 hints=\(hintCount)")
            } else {
                times.append(seconds)
            }
        }
        let p95 = Measurement.percentile(times, 0.95)
        ResultLog.row("java_inlay_warm", file: "synthetic-\(actualLines)", sizeBytes: UInt64(source.utf8.count),
                      seconds: Measurement.percentile(times, 0.50),
                      extra: "samples=\(times.count) p95=\(String(format: "%.6f", p95)) hints=\(hintCount)")
    }
}
