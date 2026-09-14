@preconcurrency import AppKit
import Foundation
import Runestone

/// Metal-specific PerfHarness subcommands. Both host a real `NSWindow` (the Metal present path
/// no-ops without one) and are meant for manual / nightly runs — they print numbers and never
/// fail CI on frame time. See "Testing strategy" / "Observability" in the Metal design.
///
///   swift run -c release PerfHarness scroll-frames synthetic --frames 180
///   swift run -c release PerfHarness scroll-frames Fixtures/short_lines_10mb.txt --baseline baseline.csv
///   swift run -c release PerfHarness snapshot-metal synthetic --out /tmp/metal-snap
enum MetalCommands {
    /// A wrapping-off ~50k-character single line plus a short keyword-coloured tail — the design's
    /// pathological instance-buffer case and a decoration sampler in one fixture.
    static let syntheticFixture: String = {
        let longLine = String(repeating: "let value = compute(a, b, c) + fallback(); ", count: 1_150)
        let code = """

        // fold me
        func demo() -> Int {
            let text = "a\tb  c" // tab + spaces
            return text.count // \u{22EF}
        }
        """
        return longLine + code
    }()

    @MainActor
    static func scrollFrames(pathOrSynthetic: String, frames: Int, baselinePath: String?) {
        let text = loadText(pathOrSynthetic)
        let (window, textView) = makeWindowedTextView(text: text, metal: true)
        defer { window.close() }
        if !textView.isMetalRenderingActive {
            warn("Metal is not active (no device or kill switch) — reported numbers are the CG path.")
        }

        let scrollableHeight = max(textView.contentSize.height - textView.frame.height, 1)
        var layoutSeconds: [Double] = []
        layoutSeconds.reserveCapacity(frames)
        for index in 0..<frames {
            let fraction = Double(index) / Double(max(frames - 1, 1))
            textView.contentOffset = CGPoint(x: 0, y: scrollableHeight * fraction)
            let timed = Measurement.time { textView.layoutSubviews() }
            Measurement.pumpRunLoop(seconds: 0.02) // let the AppKit display pass + Metal present run
            layoutSeconds.append(timed.seconds)
        }
        Measurement.pumpRunLoop(seconds: 0.1)

        let p95 = percentile(layoutSeconds, 0.95)
        let p50 = percentile(layoutSeconds, 0.50)
        let atlasKB = (textView.metalGlyphAtlasBytes + textView.metalColorAtlasBytes) / 1024
        let extra = "p50=\(fmt(p50)) drawNsP95=\(Int(textView.metalDrawNanosP95)) fragments=\(textView.metalFragmentCount) atlasKB=\(atlasKB) metalActive=\(textView.isMetalRenderingActive)"
        ResultLog.row("scroll_frames_layout_p95", file: pathOrSynthetic, sizeBytes: UInt64(text.utf8.count), seconds: p95, extra: extra)
        warn("scroll-frames: layout p95 \(fmt(p95))  \(extra)")

        if let baselinePath, let baseline = readBaseline(baselinePath, metric: "scroll_frames_layout_p95") {
            let deltaPct = baseline == 0 ? 0 : (p95 - baseline) / baseline * 100
            warn(String(format: "  vs baseline %@: %+.1f%%", fmt(baseline), deltaPct))
        }
    }

    @MainActor
    static func snapshotMetal(pathOrSynthetic: String, outputDir: String?) {
        let text = loadText(pathOrSynthetic)
        // Must be set before `TextView` init so the canvas layer is created with
        // `framebufferOnly = false` (required for `cacheDisplay` of the presented drawable).
        TextView.allowsMetalDrawableCapture = true

        let (metalWindow, metalView) = makeWindowedTextView(text: text, metal: true)
        Measurement.pumpRunLoop(seconds: 0.6)
        metalView.layoutSubviews()
        metalView.displayIfNeeded()
        Measurement.pumpRunLoop(seconds: 0.3)
        let metalActive = metalView.isMetalRenderingActive
        let atlasNonZero = metalView.metalAtlasCoverageNonZeroTexels
        let atlasTotal = metalView.metalAtlasCoverageTexelCount
        warn("  layout GlyphInstance size=\(metalView.metalGlyphInstanceSize) stride=\(metalView.metalGlyphInstanceStride) atlasNonZero=\(atlasNonZero)/\(atlasTotal) fragments=\(metalView.metalFragmentCount) instances=\(metalView.metalInstanceCount) metalActive=\(metalActive)")

        guard let glyphs = metalView.captureMetalGlyphSnapshot() else {
            warn("snapshot-metal: Metal capture unavailable (metalActive=\(metalActive))")
            metalWindow.close()
            return
        }
        let offscreenPainted = nonTransparentCount(glyphs)
        warn("  offscreen encode \(glyphs.pixelsWide)x\(glyphs.pixelsHigh): \(offscreenPainted) non-transparent px")

        var presentedPainted = -1
        var presentedRep: NSBitmapImageRep?
        if let presented = metalView.captureMetalPresentedLayer() {
            presentedRep = presented
            presentedPainted = nonTransparentCount(presented)
            warn("  presented cacheDisplay \(presented.pixelsWide)x\(presented.pixelsHigh): \(presentedPainted) non-transparent px")
        } else {
            warn("  presented cacheDisplay: unavailable")
        }

        var windowPainted = -1
        var windowShot: Shot?
        if let shot = captureWindow(metalWindow) {
            windowShot = shot
            windowPainted = inkCount(shot.rep)
            warn("  on-screen window \(shot.rep.pixelsWide)x\(shot.rep.pixelsHigh): \(windowPainted) ink px (vs corner background)")
        } else {
            warn("  on-screen window: capture failed")
        }

        if let outputDir {
            let dir = URL(fileURLWithPath: outputDir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? glyphs.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("metal-glyphs.png"))
            if let presentedRep {
                try? presentedRep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("presented.png"))
            }
            if let windowShot {
                try? windowShot.png.write(to: dir.appendingPathComponent("window.png"))
            }
        }
        metalWindow.close()

        let (cgWindow, cgView) = makeWindowedTextView(text: text, metal: false)
        Measurement.pumpRunLoop(seconds: 0.3)
        guard let cgFrame = capture(cgView) else {
            warn("snapshot-metal: could not capture the CG view")
            cgWindow.close()
            return
        }
        cgWindow.close()

        // Coverage overlap: of the pixels the Metal pass painted (alpha), how many land on a CG
        // "ink" pixel (materially brighter than the editor background). ~1.0 means Metal and CG
        // agree on where the glyphs are; a low value means misplacement / a flip / missing glyphs.
        let overlap = glyphCoverageOverlap(metalGlyphs: glyphs, cgFrame: cgFrame.rep)
        let extra = "metalCoverage=\(fmt(overlap.metalCoverageFraction)) onCGInk=\(fmt(overlap.overlapFraction)) metalActive=\(metalActive)"
        ResultLog.row("snapshot_metal_coverage", file: pathOrSynthetic, sizeBytes: UInt64(text.utf8.count), seconds: 0, extra: extra)
        warn("snapshot-metal: \(extra)")

        if let outputDir {
            let dir = URL(fileURLWithPath: outputDir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? cgFrame.png.write(to: dir.appendingPathComponent("cg.png"))
            try? glyphs.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("metal-glyphs.png"))
            warn("  wrote pngs to \(outputDir) (offscreen=\(offscreenPainted) presented=\(presentedPainted) window=\(windowPainted) atlasNonZero=\(atlasNonZero))")
        }
    }
}

private extension MetalCommands {
    @MainActor
    static func makeWindowedTextView(text: String, metal: Bool) -> (NSWindow, TextView) {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: frame)
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: text))
        textView.isMetalRenderingEnabled = metal
        textView.layoutSubviews()
        Measurement.pumpRunLoop(seconds: 0.2)
        return (window, textView)
    }

    static func loadText(_ pathOrSynthetic: String) -> String {
        if pathOrSynthetic == "synthetic" || pathOrSynthetic == "-" {
            return syntheticFixture
        }
        return (try? String(contentsOfFile: pathOrSynthetic, encoding: .utf8)) ?? syntheticFixture
    }

    struct Shot {
        var rep: NSBitmapImageRep
        var png: Data
    }

    @MainActor
    static func capture(_ view: NSView) -> Shot? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return Shot(rep: rep, png: png)
    }

    @MainActor
    static func captureWindow(_ window: NSWindow) -> Shot? {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Measurement.pumpRunLoop(seconds: 0.2)
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(
            .null,
            [.optionIncludingWindow],
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return Shot(rep: rep, png: png)
    }

    static func nonTransparentCount(_ rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData else {
            return 0
        }
        var painted = 0
        let count = rep.pixelsWide * rep.pixelsHigh * 4
        for index in stride(from: 3, to: count, by: 4) where data[index] != 0 {
            painted += 1
        }
        return painted
    }

    /// Pixels whose luma differs from the top-right corner — for opaque window screenshots
    /// where alpha is 1 everywhere.
    static func inkCount(_ rep: NSBitmapImageRep) -> Int {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 4, height > 4 else {
            return 0
        }
        let background = rep.colorAt(x: width - 2, y: 2) ?? .black
        let backgroundLuma = luma(background)
        var ink = 0
        let step = 2
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let color = rep.colorAt(x: x, y: y) else {
                    continue
                }
                if abs(luma(color) - backgroundLuma) > 0.08 {
                    ink += 1
                }
            }
        }
        return ink
    }

    static func glyphCoverageOverlap(
        metalGlyphs: NSBitmapImageRep,
        cgFrame: NSBitmapImageRep
    ) -> (metalCoverageFraction: Double, overlapFraction: Double) {
        let width = min(metalGlyphs.pixelsWide, cgFrame.pixelsWide)
        let height = min(metalGlyphs.pixelsHigh, cgFrame.pixelsHigh)
        guard width > 0, height > 0 else {
            return (0, 0)
        }
        // Editor background ≈ the frame's top-right corner (past the text on the first line).
        let background = cgFrame.colorAt(x: width - 2, y: 2) ?? .black
        let backgroundLuma = luma(background)
        var painted = 0
        var onInk = 0
        var total = 0
        let step = 2
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                total += 1
                guard let metal = metalGlyphs.colorAt(x: x, y: y), metal.alphaComponent > 0.06 else {
                    continue
                }
                painted += 1
                if let cg = cgFrame.colorAt(x: x, y: y), abs(luma(cg) - backgroundLuma) > 0.12 {
                    onInk += 1
                }
            }
        }
        let metalCoverage = total > 0 ? Double(painted) / Double(total) : 0
        let overlap = painted > 0 ? Double(onInk) / Double(painted) : 0
        return (metalCoverage, overlap)
    }

    static func luma(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return 0
        }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    static func meanAbsoluteDifference(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep
    ) -> (mean: Double, max: Double, mismatchFraction: Double) {
        let width = min(lhs.pixelsWide, rhs.pixelsWide)
        let height = min(lhs.pixelsHigh, rhs.pixelsHigh)
        guard width > 0, height > 0 else {
            return (0, 0, 0)
        }
        var total = 0.0
        var maxDiff = 0.0
        var mismatches = 0
        var samples = 0
        // Sample a grid — a full 960k-pixel compare through `colorAt` is needlessly slow for a
        // manual tool and the aggregate statistics converge well before then.
        let step = 2
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else {
                    continue
                }
                let dr = abs(a.redComponent - b.redComponent) * 255
                let dg = abs(a.greenComponent - b.greenComponent) * 255
                let db = abs(a.blueComponent - b.blueComponent) * 255
                let d = (dr + dg + db) / 3
                total += d
                maxDiff = Swift.max(maxDiff, d)
                if d > 8 { mismatches += 1 }
                samples += 1
            }
        }
        guard samples > 0 else {
            return (0, 0, 0)
        }
        return (total / Double(samples), maxDiff, Double(mismatches) / Double(samples))
    }

    static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        guard !samples.isEmpty else {
            return 0
        }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    static func readBaseline(_ path: String, metric: String) -> Double? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        for line in contents.split(separator: "\n") {
            let fields = line.split(separator: ",")
            guard fields.count >= 4, fields[0].trimmingCharacters(in: .whitespaces) == metric else {
                continue
            }
            return Double(fields[3].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func fmt(_ value: Double) -> String {
        String(format: "%.5f", value)
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
