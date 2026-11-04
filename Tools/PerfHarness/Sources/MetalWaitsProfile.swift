@preconcurrency import AppKit
import Foundation
@_spi(Benchmarks) import Penumbra

/// F10: how often does the Metal path block the calling thread on the GPU, and for how long?
///
///   swift run -c release PerfHarness metal-waits synthetic [--lines 20000] [--frames 240]
///   swift run -c release PerfHarness metal-waits synthetic --no-deferred      # sync present
///   swift run -c release PerfHarness metal-waits synthetic --discrete-atlas   # private-storage atlas
///
/// One mode per process (the atlas is process-wide). Each phase prints one line per blocking site
/// that fired; a site that never fired prints nothing, and a phase with no line is a phase with no
/// wait. Phases: cold scroll at display pace, scroll with no pause between frames, typing, and
/// far jumps that bring in glyphs the atlas has not seen.
enum MetalWaitsProfile {
    @MainActor
    static func run(pathOrSynthetic: String, lines: Int, frames: Int, deferredPresent: Bool, discreteAtlas: Bool) {
        UserDefaults.standard.set(deferredPresent, forKey: MetalDeferredPresent.defaultsKey)
        MetalWaitStats.simulatesDiscreteGPUAtlas = discreteAtlas
        let text = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-"
            ? EnterSessionProfile.syntheticJava(lines: lines)
            : ((try? String(contentsOfFile: pathOrSynthetic, encoding: .utf8)) ?? EnterSessionProfile.syntheticJava(lines: lines))
        MetalWaitStats.reset()
        let openStarted = DispatchTime.now().uptimeNanoseconds
        let (window, textView) = MetalCommands.makeWindowedTextView(text: text, metal: true)
        defer { window.close() }
        guard textView.isMetalRenderingActive else {
            warn("Metal is not active; nothing to measure.")
            return
        }
        warn("=== metal-waits \(pathOrSynthetic): deferredPresent=\(deferredPresent) discreteAtlas=\(discreteAtlas) lines=\(lines) ===")
        report("open and first paint (cold atlas)", frames: 1, started: openStarted)
        let scrollable = max(textView.contentSize.height - textView.frame.height, 1)

        func scroll(_ label: String, frames: Int, pause: Double) {
            MetalWaitStats.reset()
            let started = DispatchTime.now().uptimeNanoseconds
            for index in 0..<frames {
                let fraction = Double(index) / Double(max(frames - 1, 1))
                textView.contentOffset = CGPoint(x: 0, y: scrollable * fraction)
                textView.layoutSubviews()
                Measurement.pumpRunLoop(seconds: pause)
            }
            report(label, frames: frames, started: started)
        }

        scroll("cold scroll, \(frames) frames at display pace", frames: frames, pause: 0.016)
        scroll("scroll back, no pause between frames", frames: frames, pause: 0)

        MetalWaitStats.reset()
        var started = DispatchTime.now().uptimeNanoseconds
        let middle = textView.documentLength / 2
        textView.selectedRange = NSRange(location: middle, length: 0)
        let keystrokes = 200
        for _ in 0..<keystrokes {
            textView.insertText("x")
            Measurement.pumpRunLoop(seconds: 0.016)
        }
        report("typing, \(keystrokes) keystrokes at 60 Hz", frames: keystrokes, started: started)

        MetalWaitStats.reset()
        started = DispatchTime.now().uptimeNanoseconds
        let jumps = 40
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<jumps {
            let target = Int.random(in: 0..<max(textView.documentLength - 1, 1), using: &generator)
            textView.selectedRange = NSRange(location: target, length: 0)
            textView.scrollRangeToVisible(NSRange(location: target, length: 0))
            textView.layoutSubviews()
            Measurement.pumpRunLoop(seconds: 0.05)
        }
        report("\(jumps) far jumps", frames: jumps, started: started)
    }

    private static func report(_ label: String, frames: Int, started: UInt64) {
        let wall = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000_000
        let stats = MetalWaitStats.snapshot()
        var rows: [String] = []
        for site in MetalWaitSite.allCases {
            guard let summary = stats[site] else { continue }
            rows.append(String(
                format: "    %-18@ waits=%-5d total=%8.3f ms  max=%8.3f ms",
                site.rawValue as NSString, summary.count, summary.totalSeconds * 1000, summary.maxSeconds * 1000
            ))
        }
        warn(String(format: "  %@ (wall %.2f s): %@", label as NSString, wall, rows.isEmpty ? "no blocking waits" : ""))
        for row in rows { warn(row) }
        let total = stats.values.reduce(0) { $0 + $1.count }
        ResultLog.row("metal_waits", file: label, sizeBytes: UInt64(frames), seconds: Double(total))
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
