import Foundation
@preconcurrency import AppKit
import Runestone
import RunestoneMarkdownLanguage
import RunestoneLanguages

/// Headless benchmarks against the public `Runestone` API, driving `TextView`/`TextViewState` directly
/// with no `NSWindow`/run loop. See PERFORMANCE_AUDIT.md Phase 5 for what these numbers mean and what
/// still needs a real Instruments pass (actual on-screen frame compositing isn't observable headlessly).
enum Commands {
    struct Options: Sendable {
        var highlighted = false
        var deferred = false
        var chunked = false
        var mmap = false
        var viewport = false
        var metal = false
        /// Bundled `RunestoneLanguages` identifier (e.g. "javascript", "json", "html") to use
        /// instead of markdown when `highlighted` is set. Isolates a language with no injected
        /// child layers from markdown's per-paragraph `markdown_inline` injection.
        var language: String?
    }

    // MARK: - Shared setup

    /// Reads `path` into a `String` and reports how long that alone takes — this is the "decode the
    /// whole file before Runestone can even start" cost described in PERFORMANCE_AUDIT.md Phase 1 §2.
    private static func readFile(_ path: String) throws -> (text: String, readSeconds: Double, sizeBytes: UInt64) {
        let url = URL(fileURLWithPath: path)
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        let result = try Measurement.time("read file into String") {
            try String(contentsOf: url, encoding: .utf8)
        }
        return (result.value, result.seconds, sizeBytes)
    }

    private static func makeState(text: String, options: Options) -> TextViewState {
        let policy: SyntaxParsePolicy
        if options.viewport {
            policy = .viewport
        } else if options.deferred {
            policy = .deferred
        } else {
            policy = .eager
        }
        if options.highlighted {
            return TextViewState(text: text, language: resolvedLanguage(options), parsePolicy: policy)
        } else {
            return TextViewState(text: text)
        }
    }

    /// Defaults to markdown (has injected child layers per paragraph); `--lang <id>` selects any
    /// `RunestoneLanguages`-bundled identifier (e.g. "javascript") to isolate a single-layer parse.
    private static func resolvedLanguage(_ options: Options) -> TreeSitterLanguage {
        if let identifier = options.language, let language = TreeSitterLanguage.bundled(forIdentifier: identifier) {
            return language
        }
        return .markdown
    }

    private static func loadState(path: String, options: Options) async throws -> (TextViewState, UInt64) {
        let url = URL(fileURLWithPath: path)
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        let policy: SyntaxParsePolicy
        if options.viewport {
            policy = .viewport
        } else if options.deferred {
            policy = .deferred
        } else {
            policy = .eager
        }
        let state: TextViewState
        let io: DocumentLoadIO = options.mmap ? .memoryMapped : .streamed
        if options.highlighted {
            state = try await TextViewState.load(contentsOf: url, language: resolvedLanguage(options), parsePolicy: policy, io: io)
        } else {
            state = try await TextViewState.load(contentsOf: url, parsePolicy: policy, io: io)
        }
        return (state, sizeBytes)
    }

    /// Semaphore wait around an async load. Safe here because `DocumentLoader` does not hop to the main actor.
    private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = BlockingBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.result = .success(try await body())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }

    private static func extraLabel(_ options: Options) -> String {
        [
            options.highlighted ? "highlighted" : "plain",
            options.viewport ? "viewport" : (options.deferred ? "deferred" : "eager"),
            options.mmap ? "mmap" : (options.chunked ? "chunked" : "string_contents")
        ].joined(separator: " ")
    }

    private static func makeTextView(state: TextViewState) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        textView.setState(state)
        return textView
    }

    /// Ingest + line-index + line-ending-detection cost of `state_init`, with the tree-sitter parse
    /// excluded. A plain-text `TextViewState` runs exactly that subset (`PlainTextInternalLanguageMode`
    /// has no parse), so timing one isolates the share that does not depend on the language mode.
    /// Returns `nil` when the caller's own `state_init` is already parse-free and can be reused.
    private static func measureConstructionWithoutParse(text: String, options: Options) -> Double? {
        guard options.highlighted else {
            return nil
        }
        return Measurement.time("TextViewState.init (plain: ingest + line index, no parse)") {
            _ = TextViewState(text: text)
        }.seconds
    }

    // MARK: - open

    static func open(path: String, options: Options) throws {
        FileHandle.standardError.write("=== open \(path) (highlighted: \(options.highlighted), deferred: \(options.deferred), viewport: \(options.viewport), chunked: \(options.chunked), mmap: \(options.mmap)) ===\n".data(using: .utf8)!)
        let before = Measurement.residentMemoryBytes()
        let sizeBytes: UInt64
        let state: TextViewState
        let ingestSeconds: Double
        if options.mmap || options.chunked {
            let label = options.mmap ? "mmap" : "chunked"
            let loaded = try Measurement.time("TextViewState.load (\(label))") {
                try runBlocking { try await loadState(path: path, options: options) }
            }
            let (loadedState, fileSize) = loaded.value
            state = loadedState
            sizeBytes = fileSize
            ingestSeconds = loaded.seconds
            ResultLog.row("load", file: path, sizeBytes: sizeBytes, seconds: loaded.seconds, extra: extraLabel(options))
        } else {
            let (text, readSeconds, fileSize) = try readFile(path)
            sizeBytes = fileSize
            ResultLog.row("read", file: path, sizeBytes: sizeBytes, seconds: readSeconds)

            let stateResult = Measurement.time("TextViewState.init (line index + parse)") {
                makeState(text: text, options: options)
            }
            ResultLog.row("state_init", file: path, sizeBytes: sizeBytes, seconds: stateResult.seconds, extra: extraLabel(options))
            let lineIndexSeconds = measureConstructionWithoutParse(text: text, options: options) ?? stateResult.seconds
            ResultLog.row(
                "line_index",
                file: path,
                sizeBytes: sizeBytes,
                seconds: lineIndexSeconds,
                extra: "ingest + line index, no parse"
            )
            state = stateResult.value
            ingestSeconds = readSeconds + stateResult.seconds
        }
        // `.eager` promises a complete tree by the time `init` returns (main-thread parse abort
        // deadlines only apply under `.deferred`/`.viewport`); surface it so a fast-but-aborted
        // parse can't be mistaken for a fast, successful one.
        FileHandle.standardError.write("  isSyntaxTreeReady: \(state.isSyntaxTreeReady)\n".data(using: .utf8)!)
        ResultLog.row("syntax_tree_ready", file: path, sizeBytes: sizeBytes, seconds: 0, extra: "\(state.isSyntaxTreeReady)")

        let viewResult = Measurement.time("TextView.setState") {
            makeTextView(state: state)
        }
        ResultLog.row("set_state", file: path, sizeBytes: sizeBytes, seconds: viewResult.seconds)

        // Proxy for "time to first painted frame": force one layout pass over the initial viewport.
        let firstLayout = Measurement.time("first layoutSubviews() (first-frame proxy)") {
            viewResult.value.layoutSubviews()
        }
        ResultLog.row("first_frame_proxy", file: path, sizeBytes: sizeBytes, seconds: firstLayout.seconds)
        ResultLog.row(
            "open_first_layout",
            file: path,
            sizeBytes: sizeBytes,
            seconds: ingestSeconds + viewResult.seconds + firstLayout.seconds
        )

        let after = Measurement.residentMemoryBytes()
        ResultLog.row("rss_delta", file: path, sizeBytes: sizeBytes, seconds: 0, extra: Measurement.formatBytes(after - before))
        FileHandle.standardError.write("  RSS: \(Measurement.formatBytes(before)) -> \(Measurement.formatBytes(after))\n".data(using: .utf8)!)
        Measurement.pumpRunLoop(seconds: 1.0)
        let afterIdle = Measurement.residentMemoryBytes()
        ResultLog.row("rss_after_idle", file: path, sizeBytes: sizeBytes, seconds: 0, extra: Measurement.formatBytes(afterIdle))
        FileHandle.standardError.write("  RSS after 1s idle: \(Measurement.formatBytes(afterIdle))\n".data(using: .utf8)!)
        if options.viewport {
            Measurement.pumpRunLoop(seconds: 0.4)
            let afterParse = Measurement.residentMemoryBytes()
            ResultLog.row("rss_after_viewport_parse", file: path, sizeBytes: sizeBytes, seconds: 0, extra: Measurement.formatBytes(afterParse - before))
            FileHandle.standardError.write("  RSS after viewport parse: \(Measurement.formatBytes(afterParse))\n".data(using: .utf8)!)
        }
    }

    // MARK: - scroll

    private static func loadOrReadState(path: String, options: Options) throws -> (TextViewState, UInt64) {
        if options.mmap || options.chunked {
            return try runBlocking { try await loadState(path: path, options: options) }
        }
        let (text, _, sizeBytes) = try readFile(path)
        return (makeState(text: text, options: options), sizeBytes)
    }

    static func scroll(path: String, frames: Int, options: Options) throws {
        FileHandle.standardError.write("=== scroll \(path) (\(frames) frames) ===\n".data(using: .utf8)!)
        let (state, sizeBytes) = try loadOrReadState(path: path, options: options)
        let textView = makeTextView(state: state)
        textView.layoutSubviews()
        Measurement.pumpRunLoop()

        let totalHeight = max(textView.contentSize.height - textView.frame.height, 1)
        var maxFrameSeconds = 0.0
        var totalSeconds = 0.0
        for frameIndex in 0..<frames {
            let fraction = Double(frameIndex) / Double(max(frames - 1, 1))
            textView.contentOffset = CGPoint(x: 0, y: totalHeight * fraction)
            let frameResult = Measurement.time {
                textView.layoutSubviews()
            }
            totalSeconds += frameResult.seconds
            maxFrameSeconds = max(maxFrameSeconds, frameResult.seconds)
        }
        let avgSeconds = totalSeconds / Double(frames)
        ResultLog.row("scroll_avg_frame", file: path, sizeBytes: sizeBytes, seconds: avgSeconds)
        ResultLog.row("scroll_worst_frame", file: path, sizeBytes: sizeBytes, seconds: maxFrameSeconds)
        FileHandle.standardError.write("  avg frame: \(String(format: "%.5f", avgSeconds))s, worst: \(String(format: "%.5f", maxFrameSeconds))s\n".data(using: .utf8)!)
    }

    // MARK: - keystroke

    enum Position: String { case start, middle, end }

    static func keystroke(path: String, position: Position, options: Options, samples: Int = 1) throws {
        FileHandle.standardError.write("=== keystroke \(path) at \(position.rawValue) (\(samples) samples) ===\n".data(using: .utf8)!)
        let (state, sizeBytes) = try loadOrReadState(path: path, options: options)
        let metalWindow: NSWindow?
        let textView: TextView
        if options.metal {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let hostedView = makeTextView(state: state)
            window.contentView = hostedView
            window.makeKeyAndOrderFront(nil)
            hostedView.isMetalRenderingEnabled = true
            metalWindow = window
            textView = hostedView
        } else {
            metalWindow = nil
            textView = makeTextView(state: state)
        }
        defer { metalWindow?.close() }
        textView.layoutSubviews()

        let length = textView.documentLength
        var location: Int
        switch position {
        case .start: location = min(10, length)
        case .middle: location = length / 2
        case .end: location = max(length - 10, 0)
        }
        // Scroll the edit location into view first, matching how a real edit is always at/near the
        // visible viewport rather than an arbitrary offscreen location.
        if let textLocation = textView.textLocation(at: location) {
            _ = textView.goToLine(textLocation.lineNumber, select: .beginning)
        }

        let sampleCount = max(samples, 1)
        let warmupCount = sampleCount == 1 ? 0 : min(5, sampleCount)
        for _ in 0..<warmupCount {
            textView.replace(NSRange(location: location, length: 0), withText: "x")
            location += 1
        }

        var times: [Double] = []
        times.reserveCapacity(sampleCount)
        var metalSamples: [MetalPerformanceStats] = []
        for _ in 0..<sampleCount {
            let editResult = Measurement.time {
                textView.replace(NSRange(location: location, length: 0), withText: "x")
            }
            times.append(editResult.seconds)
            if options.metal {
                textView.layoutSubviews()
                Measurement.pumpRunLoop(seconds: 0.01)
                if let stats = textView.metalPerformanceStats {
                    metalSamples.append(stats)
                }
            }
            location += 1
        }

        let p50 = Measurement.percentile(times, 0.50)
        let p95 = Measurement.percentile(times, 0.95)
        ResultLog.row("keystroke_\(position.rawValue)", file: path, sizeBytes: sizeBytes, seconds: times.last ?? 0)
        ResultLog.row("keystroke_\(position.rawValue)_p50", file: path, sizeBytes: sizeBytes, seconds: p50)
        ResultLog.row("keystroke_\(position.rawValue)_p95", file: path, sizeBytes: sizeBytes, seconds: p95)
        emitMetalMetrics("keystroke_\(position.rawValue)", file: path, sizeBytes: sizeBytes, samples: metalSamples)
        FileHandle.standardError.write(
            "  p50: \(String(format: "%.4f", p50))s  p95: \(String(format: "%.4f", p95))s\n".data(using: .utf8)!
        )
    }

    /// Same as `keystroke`, but with occurrence highlighting enabled first — isolates
    /// `OccurrenceHighlightController.term(for:)`'s cost. Before the 2026-09-15 fix this
    /// materialized the whole document (`stringView.string`) synchronously on every keystroke,
    /// before its own debounce; comparing this against plain `keystroke` on the same fixture is
    /// the regression signal — a large gap between the two means occurrence highlighting is adding
    /// O(document size) work per edit again.
    static func occurrenceKeystroke(path: String, position: Position, options: Options, samples: Int = 1) throws {
        FileHandle.standardError.write("=== occurrence-keystroke \(path) at \(position.rawValue) (\(samples) samples) ===\n".data(using: .utf8)!)
        let (state, sizeBytes) = try loadOrReadState(path: path, options: options)
        let metalWindow: NSWindow?
        let textView: TextView
        if options.metal {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let hostedView = makeTextView(state: state)
            window.contentView = hostedView
            window.makeKeyAndOrderFront(nil)
            hostedView.isMetalRenderingEnabled = true
            metalWindow = window
            textView = hostedView
        } else {
            metalWindow = nil
            textView = makeTextView(state: state)
        }
        defer { metalWindow?.close() }
        textView.layoutSubviews()
        textView.highlightsOccurrencesOfSelection = true
        textView.languageConfigurationOverride = LanguageConfiguration(
            declarations: [],
            highlightsOccurrences: true,
            minimumOccurrenceLength: 2
        )

        let length = textView.documentLength
        var location: Int
        switch position {
        case .start: location = min(10, length)
        case .middle: location = length / 2
        case .end: location = max(length - 10, 0)
        }
        if let textLocation = textView.textLocation(at: location) {
            _ = textView.goToLine(textLocation.lineNumber, select: .beginning)
        }
        // Land the caret inside a word (not on whitespace) so `term(for:)` takes the
        // word-under-caret path `SelectNextOccurrence.wordRange` drives, matching typical typing.
        textView.selectedRange = NSRange(location: location, length: 0)

        let sampleCount = max(samples, 1)
        let warmupCount = sampleCount == 1 ? 0 : min(5, sampleCount)
        for _ in 0..<warmupCount {
            textView.replace(NSRange(location: location, length: 0), withText: "x")
            location += 1
        }

        var times: [Double] = []
        times.reserveCapacity(sampleCount)
        var metalSamples: [MetalPerformanceStats] = []
        for _ in 0..<sampleCount {
            let editResult = Measurement.time {
                textView.replace(NSRange(location: location, length: 0), withText: "x")
            }
            times.append(editResult.seconds)
            if options.metal {
                textView.layoutSubviews()
                Measurement.pumpRunLoop(seconds: 0.01)
                if let stats = textView.metalPerformanceStats {
                    metalSamples.append(stats)
                }
            }
            location += 1
        }

        let p50 = Measurement.percentile(times, 0.50)
        let p95 = Measurement.percentile(times, 0.95)
        ResultLog.row("occurrence_keystroke_\(position.rawValue)", file: path, sizeBytes: sizeBytes, seconds: times.last ?? 0)
        ResultLog.row("occurrence_keystroke_\(position.rawValue)_p50", file: path, sizeBytes: sizeBytes, seconds: p50)
        ResultLog.row("occurrence_keystroke_\(position.rawValue)_p95", file: path, sizeBytes: sizeBytes, seconds: p95)
        emitMetalMetrics("occurrence_keystroke_\(position.rawValue)", file: path, sizeBytes: sizeBytes, samples: metalSamples)
        FileHandle.standardError.write(
            "  p50: \(String(format: "%.4f", p50))s  p95: \(String(format: "%.4f", p95))s\n".data(using: .utf8)!
        )
    }

    private static func emitMetalMetrics(
        _ name: String,
        file: String,
        sizeBytes: UInt64,
        samples: [MetalPerformanceStats]
    ) {
        guard !samples.isEmpty else { return }
        let drawP95 = Measurement.percentile(samples.map(\.drawNanosP95), 0.95)
        let instances = samples.last?.glyphInstanceCount ?? 0
        let fragments = samples.last?.fragmentCount ?? 0
        let atlasBytes = (samples.last?.coverageAtlasBytes ?? 0) + (samples.last?.colorAtlasBytes ?? 0)
        let rasterCaps = samples.last?.rasterCapSkipCount ?? 0
        let rebuildNanos = samples.last?.instanceRebuildNanos ?? 0
        ResultLog.row("\(name)_metal_draw_nanos_p95", file: file, sizeBytes: sizeBytes, seconds: drawP95 / 1_000_000_000)
        ResultLog.row("\(name)_metal_instances", file: file, sizeBytes: sizeBytes, seconds: 0, extra: "\(instances)")
        ResultLog.row("\(name)_metal_fragments", file: file, sizeBytes: sizeBytes, seconds: 0, extra: "\(fragments)")
        ResultLog.row("\(name)_metal_atlas_bytes", file: file, sizeBytes: sizeBytes, seconds: 0, extra: "\(atlasBytes)")
        ResultLog.row("\(name)_metal_raster_cap_skips", file: file, sizeBytes: sizeBytes, seconds: 0, extra: "\(rasterCaps)")
        ResultLog.row("\(name)_metal_instance_rebuild_nanos", file: file, sizeBytes: sizeBytes, seconds: Double(rebuildNanos) / 1_000_000_000, extra: "\(rebuildNanos) ns")
    }

    // MARK: - goto

    static func goto(path: String, percent: Int, options: Options) throws {
        FileHandle.standardError.write("=== goto \(path) at \(percent)% ===\n".data(using: .utf8)!)
        let (state, sizeBytes) = try loadOrReadState(path: path, options: options)
        let textView = makeTextView(state: state)
        textView.layoutSubviews()

        let lineCount = max(textView.lineCount, 1)
        textView.layoutSubviews()

        let targetLine = min(max(Int(Double(lineCount) * Double(percent) / 100.0), 0), lineCount - 1)
        let gotoResult = Measurement.time("goToLine") {
            _ = textView.goToLine(targetLine, select: .beginning)
        }
        ResultLog.row("goto_\(percent)pct", file: path, sizeBytes: sizeBytes, seconds: gotoResult.seconds, extra: "line \(targetLine) of \(lineCount)")
    }

    // MARK: - search

    static func search(path: String, pattern: String, regex: Bool, options: Options) throws {
        FileHandle.standardError.write("=== search \(path) pattern=\(pattern) regex=\(regex) ===\n".data(using: .utf8)!)
        let (text, _, sizeBytes) = try readFile(path)
        let state = makeState(text: text, options: options)
        let textView = makeTextView(state: state)
        textView.layoutSubviews()

        let query = SearchQuery(text: pattern, matchMethod: regex ? .regularExpression : .contains)
        // Legacy TextView.search(for:) / SearchController path. The shipping find panel uses FindSearchEngine.
        let searchResult = Measurement.time("TextView.search(for:) — legacy SearchController path (not the shipping find panel)") {
            textView.search(for: query)
        }
        ResultLog.row(regex ? "search_regex" : "search_literal", file: path, sizeBytes: sizeBytes, seconds: searchResult.seconds, extra: "\(searchResult.value.count) matches")
    }

    // MARK: - save

    static func save(path: String, options: Options) throws {
        FileHandle.standardError.write("=== save \(path) after one edit ===\n".data(using: .utf8)!)
        let (text, _, sizeBytes) = try readFile(path)
        let state = makeState(text: text, options: options)
        let textView = makeTextView(state: state)
        textView.layoutSubviews()
        textView.replace(NSRange(location: 0, length: 0), withText: "x")

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("perfharness-save-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let viewBox = UncheckedBox(textView)
        let box = BlockingBox<DocumentWriteResult>()
        let start = DispatchTime.now()
        Task { @MainActor in
            do {
                box.result = .success(try await viewBox.value.write(to: tempURL))
            } catch {
                box.result = .failure(error)
            }
        }
        while box.result == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        FileHandle.standardError.write("  [TextView.write after 1-character edit] \(String(format: "%.4f", seconds))s\n".data(using: .utf8)!)
        let writeResult = try box.result!.get()
        ResultLog.row(
            "save_write",
            file: path,
            sizeBytes: sizeBytes,
            seconds: seconds,
            extra: "generationMatched=\(writeResult.generationMatched) compacted=\(writeResult.compacted)"
        )
    }
}

private final class BlockingBox<Value>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) {
        self.value = value
    }
}
