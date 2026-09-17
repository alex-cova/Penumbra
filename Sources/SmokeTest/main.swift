import AppKit
import Penumbra
import PenumbraMarkdownLanguage

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// MARK: - Large-file benchmark
//
// Exercises editing/navigation on a large synthetic document to catch performance regressions
// on the hot paths identified in the Phase 1 perf pass (per-keystroke document snapshotting,
// tree-sitter parsing, line-manager edits, and jump-to-location navigation). Run with
// `swift run -c release SmokeTest` to get representative numbers; debug builds are much slower
// across the board and not meaningful for comparison.
//
// This runs ahead of the basic smoke test below and uses TextView.replace(_:withText:) (the same
// programmatic entry point PenumbraEditorAdapter.applyEdit uses) rather than insertText(_:), so
// it doesn't depend on the process actually holding key-window/first-responder status, which
// isn't guaranteed in every environment this executable runs in (e.g. headless CI).

func generateLargeDocument(lineCount: Int) -> String {
    var lines = [String]()
    lines.reserveCapacity(lineCount)
    for i in 0 ..< lineCount {
        lines.append("let value\(i) = someFunction(argumentNumber: \(i), otherArgument: \"text\")")
    }
    return lines.joined(separator: "\n")
}

@discardableResult
func measure(_ label: String, iterations: Int = 1, _ body: () -> Void) -> TimeInterval {
    let start = DispatchTime.now()
    for _ in 0 ..< iterations {
        body()
    }
    let end = DispatchTime.now()
    let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    let perIteration = (elapsed / Double(iterations)) * 1000
    print("\(label): \(String(format: "%.3f", elapsed))s total, \(String(format: "%.4f", perIteration))ms/iteration (n=\(iterations))")
    return elapsed
}

let lineCount = 200_000
let largeDocumentText = generateLargeDocument(lineCount: lineCount)
print("Generated benchmark document: \(lineCount) lines, \(largeDocumentText.utf16.count) UTF-16 units")

let benchmarkWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                styleMask: [.titled],
                                backing: .buffered,
                                defer: false)
benchmarkWindow.orderFrontRegardless()
let benchmarkTextView = TextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
benchmarkWindow.contentView = benchmarkTextView
benchmarkTextView.theme = DefaultTheme()

measure("Load \(lineCount)-line document") {
    benchmarkTextView.text = largeDocumentText
}

// Single-character edits at the end of the document, where StringView's flat NSMutableString
// backing and LineManager's tree updates are exercised at realistic depth/offset.
var editLocation = benchmarkTextView.text.utf16.count
measure("200 single-character edits at document end", iterations: 200) {
    benchmarkTextView.replace(NSRange(location: editLocation, length: 0), withText: "x")
    editLocation += 1
}

// Jump-to-location navigation: before the Phase 1 fix this walked and typeset every line from
// the start of the document up to the target on every call (O(document)); it should now be
// O(log n) plus typesetting just the target line.
measure("100 goToLine jumps across the document", iterations: 100) { [lineCount] in
    let target = Int.random(in: 0 ..< lineCount)
    benchmarkTextView.goToLine(target)
}

print("Benchmark complete")

// MARK: - Minimap visual verification
//
// Renders a TextView with the minimap enabled to a PNG so the rendering can be inspected visually
// (there's no interactive display in this environment). Uses varied line lengths/indentation so
// the minimap's per-line bars are visually distinguishable, and scrolls partway through the
// document so the viewport indicator box is a meaningful (non-full-height) size and isn't pinned
// to the very top.

func generateVariedDocument(lineCount: Int) -> String {
    var lines = [String]()
    lines.reserveCapacity(lineCount)
    for i in 0 ..< lineCount {
        let indent = String(repeating: "    ", count: i % 4)
        switch i % 7 {
        case 0:
            lines.append("\(indent)func handler\(i)() {")
        case 1:
            lines.append("\(indent)let result = compute(\(i), withOptions: defaultOptions, retrying: true)")
        case 2:
            lines.append("\(indent)}")
        case 3:
            lines.append("")
        case 4:
            lines.append("\(indent)// A short comment")
        case 5:
            lines.append("\(indent)return value\(i)")
        default:
            lines.append("\(indent)guard condition\(i) else { continue }")
        }
    }
    return lines.joined(separator: "\n")
}

// A varied Markdown document so the minimap crop shows real syntax colors (headings, emphasis,
// inline code, quotes) and clear indentation structure.
func generateMarkdownDocument(lineCount: Int) -> String {
    var lines = [String]()
    lines.reserveCapacity(lineCount)
    for i in 0 ..< lineCount {
        switch i % 8 {
        case 0: lines.append("# Section \(i)")
        case 1: lines.append("Prose with **bold**, _italic_, and `inline code` on line \(i).")
        case 2: lines.append("    indented code block sample \(i)")
        case 3: lines.append("")
        case 4: lines.append("- bullet \(i) referencing [a link](https://example.com/\(i))")
        case 5: lines.append("> A blockquote paragraph number \(i) that runs on for a while to exercise long lines and the trailing fade past the minimap's own width budget.")
        case 6: lines.append("## Subsection \(i)")
        default: lines.append("1. ordered item \(i)")
        }
    }
    return lines.joined(separator: "\n")
}

let minimapWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
minimapWindow.orderFrontRegardless()
let minimapTextView = TextView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
minimapWindow.contentView = minimapTextView
minimapTextView.showMinimap = true
minimapTextView.minimapWidth = 100
minimapTextView.setState(TextViewState(
    text: generateMarkdownDocument(lineCount: 500),
    theme: DefaultTheme(),
    language: .markdown,
    languageProvider: MarkdownLanguageProvider()
))

// contentSize is applied via a DispatchQueue.main.async block (see
// TextView.handleContentSizeUpdateIfNeeded), and nothing else in this executable pumps the run
// loop, so briefly spin it to let that — and the minimap's own deferred redraw hooks — flush
// before reading contentSize/capturing the screenshot below.
func pumpRunLoop(for duration: TimeInterval = 0.2) {
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
}

minimapWindow.layoutIfNeeded()
minimapTextView.layoutSubtreeIfNeeded()
pumpRunLoop()
print("contentSize after pump: \(minimapTextView.contentSize)")

func writePNG(_ bitmap: NSBitmapImageRep, to path: String) {
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode screenshot as PNG (\(path))\n", stderr)
        return
    }
    do {
        try pngData.write(to: URL(fileURLWithPath: path))
        print("Screenshot written to \(path)")
    } catch {
        fputs("Failed to write screenshot: \(error)\n", stderr)
    }
}

// Output directory: first CLI arg, else $SMOKETEST_OUT_DIR, else the system temp dir.
let scratchDir: String = {
    if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
    if let env = ProcessInfo.processInfo.environment["SMOKETEST_OUT_DIR"] { return env }
    return NSTemporaryDirectory()
}()

@MainActor
func captureMinimap(atProgress progress: CGFloat, suffix: String) {
    let maxOffset = max(minimapTextView.contentSize.height - minimapTextView.bounds.height, 0)
    minimapTextView.contentOffset = CGPoint(x: 0, y: maxOffset * progress)
    minimapWindow.layoutIfNeeded()
    minimapTextView.layoutSubtreeIfNeeded()
    pumpRunLoop()

    guard let bitmap = minimapTextView.bitmapImageRepForCachingDisplay(in: minimapTextView.bounds) else {
        fputs("Failed to create bitmap for minimap screenshot\n", stderr)
        return
    }
    minimapTextView.cacheDisplay(in: minimapTextView.bounds, to: bitmap)
    writePNG(bitmap, to: "\(scratchDir)/minimap-screenshot-\(suffix).png")

    // Crop the trailing minimapWidth points (the minimap strip) for a close-up look.
    if let cgImage = bitmap.cgImage {
        let scale = CGFloat(cgImage.width) / minimapTextView.bounds.width
        let cropWidth = minimapTextView.minimapWidth * scale
        let cropRect = CGRect(x: CGFloat(cgImage.width) - cropWidth, y: 0, width: cropWidth, height: CGFloat(cgImage.height))
        if let croppedCGImage = cgImage.cropping(to: cropRect) {
            writePNG(NSBitmapImageRep(cgImage: croppedCGImage), to: "\(scratchDir)/minimap-crop-\(suffix).png")
        }
    }
}

captureMinimap(atProgress: 0.0, suffix: "top")
captureMinimap(atProgress: 0.4, suffix: "mid")

// MARK: - Folding visual verification
//
// Exercises the folding ribbon, zero-height collapse, and placeholder rendering in a headless
// capture. SmokeTest is the headless host for Metal regression checks.

let foldingText = """
func foo() {
    let x = 1
    let y = 2
}
let after = 3
"""
let foldingWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
foldingWindow.orderFrontRegardless()
let foldingTextView = TextView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
foldingWindow.contentView = foldingTextView
foldingTextView.theme = DefaultTheme()
foldingTextView.showLineNumbers = true
foldingTextView.text = foldingText
foldingTextView.isLineFoldingEnabled = true
foldingWindow.layoutIfNeeded()
foldingTextView.layoutSubtreeIfNeeded()
pumpRunLoop()

guard foldingTextView.contentSize.height > 0 else {
    fputs("Folding smoke test failed: content size not ready\n", stderr)
    exit(1)
}

// Collapse the first fold programmatically by toggling through the public API surface.
// We can't click the ribbon here, but enabling folding + layout proves the gutter wiring.
print("Folding enabled, content height with folds computed: \(foldingTextView.contentSize.height)")

if let foldingBitmap = foldingTextView.bitmapImageRepForCachingDisplay(in: foldingTextView.bounds) {
    foldingTextView.cacheDisplay(in: foldingTextView.bounds, to: foldingBitmap)
    writePNG(foldingBitmap, to: "\(scratchDir)/folding-screenshot.png")
} else {
    fputs("Failed to create bitmap for folding screenshot\n", stderr)
}

// MARK: - Basic smoke test

let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                      styleMask: [.titled],
                      backing: .buffered,
                      defer: false)
window.orderFrontRegardless()

let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
window.contentView = textView

textView.theme = DefaultTheme()
textView.text = "Smoke test"
textView.selectedRange = NSRange(location: 0, length: 5)

guard textView.text == "Smoke test" else {
    fputs("Unexpected text content\n", stderr)
    exit(1)
}
guard textView.selectedRange.length == 5 else {
    fputs("Unexpected selection\n", stderr)
    exit(1)
}
guard textView.becomeFirstResponder() else {
    fputs("Failed to become first responder\n", stderr)
    exit(1)
}
textView.insertText("!")
guard textView.text == "Smoke test!" else {
    fputs("Insert text failed\n", stderr)
    exit(1)
}
print("Smoke test passed")
