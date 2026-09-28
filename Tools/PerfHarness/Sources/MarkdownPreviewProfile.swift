@preconcurrency import AppKit
import Foundation
@_spi(Benchmarks) import Penumbra
import PenumbraLanguages

/// `markdown-preview`: parse, raster (mermaid, code fences), layout and scroll costs of the
/// Markdown preview, plus edit-to-present through `MarkdownPreviewController`. Baselines and
/// results live in docs/EDITOR_PERF_PLAN.md.
///
///   swift run -c release PerfHarness markdown-preview synthetic [--sections 200] [--samples 5]
///   swift run -c release PerfHarness markdown-preview Path/To/README.md
@MainActor
enum MarkdownPreviewProfile {
    static func run(pathOrSynthetic: String, sections: Int, samples: Int) {
        let isSynthetic = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-"
        let text = isSynthetic
            ? syntheticMarkdown(sections: sections)
            : ((try? String(contentsOfFile: pathOrSynthetic, encoding: .utf8)) ?? syntheticMarkdown(sections: sections))
        let file = isSynthetic ? "synthetic-md-\(sections)" : pathOrSynthetic
        let sizeBytes = UInt64(text.utf8.count)
        let editedText = editedMarkdown(text)

        // Parse.
        var document = MarkdownPreviewDocument.parse(text)
        let parseTimes = (0 ..< samples).map { _ in
            timed { document = MarkdownPreviewDocument.parse(text) }
        }
        let mermaidCount = document.blocks.filter { if case .mermaid = $0.kind { return true } else { return false } }.count
        let codeCount = document.blocks.filter { if case .codeBlock = $0.kind { return true } else { return false } }.count
        warn("=== markdown-preview \(file): \(document.blocks.count) blocks, \(mermaidCount) mermaid, \(codeCount) code ===")
        report("parse", parseTimes, file: file, sizeBytes: sizeBytes, extra: "blocks=\(document.blocks.count)")
        let parseCache = MarkdownPreviewParseCache()
        _ = MarkdownPreviewDocument.parse(text, cache: parseCache)
        let parseWarmTimes = (0 ..< samples).map { sample in
            timed { _ = MarkdownPreviewDocument.parse(sample.isMultiple(of: 2) ? editedText : text, cache: parseCache) }
        }
        report("parse_warm", parseWarmTimes, file: file, sizeBytes: sizeBytes)

        // Raster (mermaid + code fences), cold then after a one-paragraph edit.
        let style = MarkdownPreviewStyle()
        let contentWidth: CGFloat = 760
        let resolver: @Sendable (String) -> TreeSitterLanguage? = { BundledLanguages.language(forIdentifier: $0) }
        let rasterCache = MarkdownPreviewRasterCache()
        func rasterize(
            _ document: MarkdownPreviewDocument,
            cache: MarkdownPreviewRasterCache = rasterCache
        ) -> (MarkdownPreviewRasterResult, Double) {
            var result = MarkdownPreviewRasterResult()
            let seconds = timed {
                result = awaitResult {
                    await MarkdownPreviewRasterizer.rasterize(
                        document: document, style: style, contentWidth: contentWidth,
                        codeBlockLanguageResolver: resolver, cache: cache
                    )
                }
            }
            return (result, seconds)
        }
        let (raster, coldSeconds) = rasterize(document)
        report("raster_cold", [coldSeconds], file: file, sizeBytes: sizeBytes,
               extra: "images=\(raster.images.count) code=\(raster.highlightedCode.count)")
        for (label, keep) in [("mermaid", { (k: MarkdownPreviewBlock.Kind) -> Bool in if case .mermaid = k { return true }; return false }),
                              ("code", { (k: MarkdownPreviewBlock.Kind) -> Bool in if case .codeBlock = k { return true }; return false })] {
            let only = MarkdownPreviewDocument(blocks: document.blocks.filter { keep($0.kind) })
            let seconds = rasterize(only, cache: MarkdownPreviewRasterCache()).1
            report("raster_only_\(label)", [seconds], file: file, sizeBytes: sizeBytes, extra: "blocks=\(only.blocks.count)")
        }
        let editedDocument = MarkdownPreviewDocument.parse(editedText)
        let warmTimes = (0 ..< samples).map { _ in rasterize(editedDocument).1 }
        report("raster_warm", warmTimes, file: file, sizeBytes: sizeBytes)

        // Layout + scroll in a hosted window (Metal on, as in Umbra).
        let frame = CGRect(x: 0, y: 0, width: 800, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.close() }
        let preview = MarkdownPreviewView(frame: frame)
        preview.usesMetalRendering = true
        window.contentView = preview
        window.makeKeyAndOrderFront(nil)
        Measurement.pumpRunLoop(seconds: 0.3)

        let layoutTimes = (0 ..< samples).map { index in
            timed {
                preview.document = index.isMultiple(of: 2) ? document : editedDocument
                preview.rasterImages = raster.images
                preview.rasterNaturalSizes = raster.naturalSizes
                preview.highlightedCode = raster.highlightedCode
                preview.layoutSubtreeIfNeeded()
            }
        }
        report("layout", layoutTimes, file: file, sizeBytes: sizeBytes, extra: "metal=\(preview.benchmarkIsMetalActive)")
        let measureTimes = (0 ..< samples).map { _ in timed { _ = preview.preferredContentSize(forWidth: frame.width) } }
        report("layout_measure", measureTimes, file: file, sizeBytes: sizeBytes, extra: "misses=\(preview.benchmarkMeasureMisses)")
        let noopTimes = (0 ..< samples).map { _ in timed { preview.benchmarkForceLayout() } }
        report("layout_noop", noopTimes, file: file, sizeBytes: sizeBytes)

        let contentHeight = preview.preferredContentSize(forWidth: frame.width).height
        let step: CGFloat = 120
        var scrollTimes: [Double] = []
        var y: CGFloat = 0
        while y + frame.height < contentHeight, scrollTimes.count < 400 {
            y += step
            scrollTimes.append(timed {
                preview.benchmarkScroll(toY: y)
            })
            Measurement.pumpRunLoop(seconds: 0.002)
        }
        report("scroll_step", scrollTimes, file: file, sizeBytes: sizeBytes,
               extra: "steps=\(scrollTimes.count) height=\(Int(contentHeight))")

        // Edit to present through the controller (debounce disabled).
        let textView = TextView(frame: frame)
        textView.languageIdentifier = "markdown"
        textView.isMetalRenderingEnabled = true
        textView.setState(TextViewState(text: text))
        let controller = MarkdownPreviewController(textView: textView)
        controller.benchmarkParseDebounceNanoseconds = 0
        controller.codeBlockLanguageResolver = { BundledLanguages.language(forIdentifier: $0) }
        controller.installTextObservation(chaining: nil)
        let host = NSView(frame: frame)
        textView.frame = host.bounds
        host.addSubview(textView)
        controller.embed(editorView: host)
        controller.containerView.frame = frame
        window.contentView = controller.containerView
        controller.toggle()
        let openSeconds = timed {
            awaitVoid { await controller.benchmarkWaitForPendingWork() }
            controller.containerView.layoutSubtreeIfNeeded()
        }
        report("controller_open", [openSeconds], file: file, sizeBytes: sizeBytes)
        let middle = (text as NSString).length / 2
        var editTimes: [Double] = []
        for sample in 0 ..< samples {
            textView.selectedRange = NSRange(location: middle + sample, length: 0)
            editTimes.append(timed {
                textView.insertText("x")
                awaitVoid { await controller.benchmarkWaitForPendingWork() }
                controller.containerView.layoutSubtreeIfNeeded()
            })
        }
        report("edit_to_present", editTimes, file: file, sizeBytes: sizeBytes)
    }

    // MARK: - Fixture

    static func syntheticMarkdown(sections: Int) -> String {
        var out: [String] = ["# Synthetic preview document", ""]
        for section in 0 ..< sections {
            out.append("## Section \(section)")
            out.append("")
            for paragraph in 0 ..< 3 {
                out.append("Paragraph \(paragraph) of section \(section) has **bold text**, *emphasis*, `inline code` "
                    + "and a [link](https://example.com/\(section)). It runs long enough to wrap across a few "
                    + "lines in a typical preview pane, which is what makes CoreText measurement cost real.")
                out.append("")
            }
            for item in 0 ..< 4 {
                out.append("- List item \(item) with `code` and **weight**")
            }
            out.append("- [x] Done task")
            out.append("")
            if section % 7 == 3 {
                out.append("```swift")
                out.append("struct Section\(section) {")
                out.append("    let value = \(section)")
                out.append("    func compute(_ input: Int) -> Int { input * value + \(section) }")
                out.append("}")
                out.append("```")
                out.append("")
            }
            if section % 20 == 10 {
                out.append("```mermaid")
                if section % 40 == 10 {
                    // A realistic architecture flowchart: ~24 nodes, subgraphs, labelled edges.
                    out.append("flowchart TD")
                    for group in 0 ..< 4 {
                        out.append("    subgraph G\(group)[Layer \(group)]")
                        for node in 0 ..< 6 {
                            out.append("        N\(section)_\(group)_\(node)[Component \(group).\(node)]")
                        }
                        out.append("    end")
                    }
                    for group in 0 ..< 4 {
                        for node in 0 ..< 6 {
                            let next = "N\(section)_\((group + 1) % 4)_\((node * 2) % 6)"
                            out.append("    N\(section)_\(group)_\(node) -->|call \(node)| \(next)")
                        }
                    }
                } else {
                    out.append("sequenceDiagram")
                    let actors = ["Client", "Gateway", "Auth", "Service", "Database", "Cache"]
                    for step in 0 ..< 18 {
                        let from = actors[step % actors.count]
                        let to = actors[(step * 5 + 1) % actors.count]
                        out.append("    \(from)->>\(to): Request \(step) for section \(section)")
                    }
                }
                out.append("```")
                out.append("")
            }
            if section % 25 == 5 {
                out.append("| Name | Value | Notes |")
                out.append("| :--- | ---: | :---: |")
                for row in 0 ..< 5 {
                    out.append("| row \(row) | \(row * section) | some *notes* here |")
                }
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }

    /// Changes one paragraph in the middle of the document, leaving every fence untouched.
    private static func editedMarkdown(_ text: String) -> String {
        guard let range = text.range(of: "Paragraph 1 of section 100 ") ?? text.range(of: "\n\n") else { return text + "\nx" }
        return text.replacingCharacters(in: range, with: "Paragraph one (edited) of section 100 ")
    }

    // MARK: - Helpers

    private static func timed(_ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        autoreleasepool { body() }
        return CFAbsoluteTimeGetCurrent() - start
    }

    private static func awaitResult<T>(_ operation: @escaping @MainActor () async -> T) -> T {
        var result: T?
        Task { @MainActor in result = await operation() }
        while result == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        return result!
    }

    private static func awaitVoid(_ operation: @escaping @MainActor () async -> Void) {
        _ = awaitResult { await operation(); return true }
    }

    private static func report(_ metric: String, _ times: [Double], file: String, sizeBytes: UInt64, extra: String = "") {
        let median = Measurement.percentile(times, 0.5)
        let p95 = Measurement.percentile(times, 0.95)
        let maxTime = times.max() ?? 0
        warn(String(format: "  %-18@ median=%8.2f ms  p95=%8.2f ms  max=%8.2f ms  n=%d %@",
                    metric as NSString, median * 1000, p95 * 1000, maxTime * 1000, times.count, extra as NSString))
        let fields = ["p95=\(String(format: "%.6f", p95))", "n=\(times.count)", extra].filter { !$0.isEmpty }
        ResultLog.row(metric, file: file, sizeBytes: sizeBytes, seconds: median, extra: fields.joined(separator: " "))
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
