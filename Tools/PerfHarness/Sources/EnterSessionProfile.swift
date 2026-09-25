@preconcurrency import AppKit
import Foundation
@_spi(Benchmarks) import Penumbra
import PenumbraLanguages

/// `enter-session`: an Umbra-like editing session on a Java file, reporting `LineManager` handle
/// growth and Enter latency by caret position. Baseline and targets live in
/// docs/EDITOR_PERF_PLAN.md.
///
///   swift run -c release PerfHarness enter-session synthetic [--lines 120000] [--samples 15]
///   swift run -c release PerfHarness enter-session Path/To/Big.java
///   swift run -c release PerfHarness enter-session synthetic --enter-only --samples 2000  # for `sample`
///
/// The text view matches Umbra's defaults: line numbers, folding, minimap, method separators and
/// Metal on. Each Enter is timed as `insertText("\n")` plus `layoutIfNeeded()`, then undone with
/// Backspace so every position is measured on the same text.
@MainActor
enum EnterSessionProfile {
    static func run(pathOrSynthetic: String, lines: Int, samples: Int, holdSeconds: Double = 0, enterOnly: Bool = false) {
        let text = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-"
            ? syntheticJava(lines: lines)
            : ((try? String(contentsOfFile: pathOrSynthetic, encoding: .utf8)) ?? syntheticJava(lines: lines))
        let file = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-" ? "synthetic-\(lines)" : pathOrSynthetic
        let sizeBytes = UInt64(text.utf8.count)
        let (window, textView) = makeTextView(text: text)
        defer { window.close() }
        let lineCount = textView.lineHandleStatistics.lineCount
        warn("=== enter-session \(file): \(lineCount) lines, metal=\(textView.isMetalRenderingActive) ===")

        func reportHandles(_ step: String) {
            let stats = textView.lineHandleStatistics
            let malloc = Measurement.mallocBytesInUse()
            warn(String(format: "  %-34@ live=%7d created=%7d malloc=%@", step as NSString, stats.liveHandles,
                        stats.handlesCreated, Measurement.formatBytes(malloc) as NSString))
            ResultLog.row("handles_\(step)", file: file, sizeBytes: sizeBytes, seconds: 0,
                          extra: "live=\(stats.liveHandles) created=\(stats.handlesCreated) lines=\(stats.lineCount) malloc=\(malloc)")
        }

        func measureEnter(_ label: String, row: Int) {
            _ = textView.goToLine(row, select: .end)
            pump(textView)
            // Warm up once so the first sample doesn't carry one-off costs (atlas, caches).
            textView.insertText("\n")
            textView.deleteBackward()
            pump(textView)
            textView.resetLineHandleCounters()
            let metalBefore = textView.metalPerformanceStats
            var times: [Double] = []
            times.reserveCapacity(samples)
            // Each step in its own pool, as an app event would be: top-level code never drains
            // the outer pool, which otherwise shows up as ~16 MB of pool pages at 120k lines.
            for _ in 0 ..< samples {
                autoreleasepool {
                    let start = CFAbsoluteTimeGetCurrent()
                    textView.insertText("\n")
                    textView.layoutIfNeeded()
                    times.append(CFAbsoluteTimeGetCurrent() - start)
                }
                Measurement.pumpRunLoop(seconds: 0.003)
            }
            let visits = textView.lineHandleStatistics.shiftVisits / max(samples, 1)
            // Paint work per Enter: glyph extracts and decoration builds (lines below the caret
            // only move, so ideally neither grows with the viewport).
            let metalAfter = textView.metalPerformanceStats
            let extracts = ((metalAfter?.glyphExtractCount ?? 0) - (metalBefore?.glyphExtractCount ?? 0)) / max(samples, 1)
            let decorations = ((metalAfter?.decorationBuildCount ?? 0) - (metalBefore?.decorationBuildCount ?? 0)) / max(samples, 1)
            for _ in 0 ..< samples {
                autoreleasepool {
                    textView.deleteBackward()
                }
            }
            pump(textView)
            let median = Measurement.percentile(times, 0.5)
            let p90 = Measurement.percentile(times, 0.9)
            let live = textView.lineHandleStatistics.liveHandles
            warn(String(format: "  Enter %-28@ median=%7.3f ms  p90=%7.3f ms  shiftVisits/Enter=%d  live=%d  extracts/Enter=%d  decorations/Enter=%d",
                        label as NSString, median * 1000, p90 * 1000, visits, live, extracts, decorations))
            ResultLog.row("enter_\(label)", file: file, sizeBytes: sizeBytes, seconds: median,
                          extra: "p90=\(String(format: "%.6f", p90)) shiftVisits=\(visits) live=\(live) extracts=\(extracts) decorations=\(decorations)")
        }

        let top = min(40, lineCount - 1)
        let middle = lineCount / 2
        let end = max(lineCount - 20, 0)
        reportHandles("open")
        measureEnter("fresh_top", row: top)
        measureEnter("fresh_middle", row: middle)
        // Only Enter in the middle of the file, e.g. with many samples under a profiler.
        if enterOnly {
            return
        }

        // Read the whole file a page at a time, then jump around and select occurrences.
        // Each page is timed as offset change + layout + display (editor, gutter, minimap).
        let page = max(textView.bounds.height, 1)
        var offsetY: CGFloat = 0
        var pageTimes: [Double] = []
        while offsetY < textView.contentSize.height {
            autoreleasepool {
                let start = CFAbsoluteTimeGetCurrent()
                textView.contentOffset = CGPoint(x: 0, y: offsetY)
                textView.layoutIfNeeded()
                textView.displayIfNeeded()
                pageTimes.append(CFAbsoluteTimeGetCurrent() - start)
            }
            Measurement.pumpRunLoop(seconds: 0.01)
            offsetY += page
        }
        let pageMedian = Measurement.percentile(pageTimes, 0.5)
        let pageP90 = Measurement.percentile(pageTimes, 0.9)
        warn(String(format: "  Scroll page (%d pages)              median=%7.3f ms  p90=%7.3f ms",
                    pageTimes.count, pageMedian * 1000, pageP90 * 1000))
        ResultLog.row("scroll_page", file: file, sizeBytes: sizeBytes, seconds: pageMedian,
                      extra: "p90=\(String(format: "%.6f", pageP90)) pages=\(pageTimes.count)")
        reportHandles("scrolled_whole_file")
        for fraction in [0.1, 0.5, 0.9] {
            _ = textView.goToLine(Int(Double(lineCount) * fraction))
            pump(textView)
        }
        reportHandles("goto_jumps")
        let word = (textView.text as NSString).range(of: "total")
        if word.location != NSNotFound {
            textView.selectedRange = word
            // Selecting (plus the layout it triggers), then scrolling while every match is
            // selected: selection chrome is refreshed on each layout pass.
            let selectStart = CFAbsoluteTimeGetCurrent()
            autoreleasepool {
                textView.selectAllOccurrences()
                textView.layoutIfNeeded()
                textView.displayIfNeeded()
            }
            let selectTime = CFAbsoluteTimeGetCurrent() - selectStart
            let selectionCount = textView.selectedRanges.count
            pump(textView)
            var selectedPageTimes: [Double] = []
            for index in 0 ..< 40 {
                autoreleasepool {
                    let start = CFAbsoluteTimeGetCurrent()
                    textView.contentOffset = CGPoint(x: 0, y: CGFloat(index) * page)
                    textView.layoutIfNeeded()
                    textView.displayIfNeeded()
                    selectedPageTimes.append(CFAbsoluteTimeGetCurrent() - start)
                }
                Measurement.pumpRunLoop(seconds: 0.01)
            }
            let selectedPageMedian = Measurement.percentile(selectedPageTimes, 0.5)
            warn(String(format: "  Select All Occurrences (%d)          %7.3f ms  scroll page with them median=%7.3f ms",
                        selectionCount, selectTime * 1000, selectedPageMedian * 1000))
            ResultLog.row("select_all_occurrences", file: file, sizeBytes: sizeBytes, seconds: selectTime,
                          extra: "selections=\(selectionCount)")
            ResultLog.row("scroll_page_with_selections", file: file, sizeBytes: sizeBytes, seconds: selectedPageMedian,
                          extra: "p90=\(String(format: "%.6f", Measurement.percentile(selectedPageTimes, 0.9)))")
            textView.selectedRange = NSRange(location: 0, length: 0)
            pump(textView)
        }
        reportHandles("select_all_occurrences")
        // What the per-line caches cost: the memory-warning handlers drop line controllers (and
        // their typesetting) except for visible lines.
        NotificationCenter.default.post(name: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil)
        pump(textView)
        reportHandles("after_memory_warning")

        measureEnter("walked_top", row: top)
        measureEnter("walked_middle", row: middle)
        measureEnter("walked_end", row: end)

        // Keep the process (and text view) alive for `heap <pid>` / `vmmap` inspection.
        if holdSeconds > 0 {
            warn("  holding for \(holdSeconds)s: pid \(ProcessInfo.processInfo.processIdentifier)")
            Measurement.pumpRunLoop(seconds: holdSeconds)
        }
    }

    private static func makeTextView(text: String) -> (NSWindow, TextView) {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: frame)
        textView.showLineNumbers = true
        textView.isLineFoldingEnabled = true
        textView.showMinimap = true
        textView.showMethodSeparators = true
        textView.isMetalRenderingEnabled = true
        // Umbra sets this; it selects the Java declaration rules (method separators).
        textView.languageIdentifier = "java"
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: text, language: TreeSitterLanguage.bundled(forIdentifier: "java") ?? .java))
        textView.layoutIfNeeded()
        Measurement.pumpRunLoop(seconds: 1.5)
        textView.layoutIfNeeded()
        return (window, textView)
    }

    private static func pump(_ textView: TextView) {
        autoreleasepool {
            textView.layoutIfNeeded()
            textView.displayIfNeeded()
        }
        Measurement.pumpRunLoop(seconds: 0.01)
    }

    /// Classes of eight small methods: realistic nesting and indentation for the Enter indenter.
    static func syntheticJava(lines target: Int) -> String {
        var out = ["package demo;", "", "import java.util.*;", ""]
        var classIndex = 0
        while out.count < target {
            out.append("public class Service\(classIndex) {")
            out.append("    private final Map<String, Integer> cache = new HashMap<>();")
            for method in 0 ..< 8 {
                out.append("")
                out.append("    /** Computes value \(method). */")
                out.append("    public int compute\(method)(String key, int limit) {")
                out.append("        int total = 0;")
                out.append("        for (int i = 0; i < limit; i++) {")
                out.append("            total += key.length() * i + \(method);")
                out.append("        }")
                out.append("        return cache.getOrDefault(key, total);")
                out.append("    }")
            }
            out.append("}")
            out.append("")
            classIndex += 1
        }
        return out.joined(separator: "\n")
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
