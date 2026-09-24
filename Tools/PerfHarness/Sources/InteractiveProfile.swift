import Foundation
@preconcurrency import AppKit
import EditorIntelligence
import Penumbra
import PenumbraLanguages

/// Release-mode stage profile for one keystroke command.
///
/// Prints median / p95 / p99 / worst for the editing operations and the intelligence stages.
/// Frame presentation is attempted; a headless failure is printed and is not turned into a frame time.
@MainActor
enum InteractiveProfile {
    private static let smallLineCount = 80
    private static let largeLineCount = 24_000
    private static let smallSamples = 16
    private static let largeSamples = 8

    private struct Samples {
        var insert: [Double] = []
        var delete: [Double] = []
        var paste: [Double] = []
        var multiCursor: [Double] = []
        var selection: [Double] = []
        var undo: [Double] = []
        var redo: [Double] = []
        var cursorMovement: [Double] = []
        var textMutation: [Double] = []
        var caret: [Double] = []
        var incrementalParse: [Double] = []
        var visibleUpdate: [Double] = []
        var mainThread: [Double] = []
        var completionPrepare: [Double] = []
    }

    static func run(referencePath: String) throws {
        note("=== interactive profile (reference \(referencePath)) ===")
        let trace = EditorPerformanceTrace.shared
        let wasEnabled = trace.isEnabled
        trace.isEnabled = true
        trace.reset()
        defer {
            trace.isEnabled = wasEnabled
            trace.reset()
        }

        let smallText = generatedSource(lineCount: smallLineCount)
        let largeText = generatedSource(lineCount: largeLineCount)
        note("  generated small \(smallText.utf8.count) bytes, large \(largeText.utf8.count) bytes")

        note("  plain small")
        let smallView = makeTextView(text: smallText, language: nil)
        warmUp(smallView)
        let small = collectEditingOperations(on: smallView, samples: smallSamples)

        note("  plain large")
        let largeView = makeTextView(text: largeText, language: nil)
        warmUp(largeView)
        let large = collectEditingOperations(on: largeView, samples: largeSamples)

        note("  highlighted")
        let highlightedSmall = collectHighlightedInserts(text: smallText, samples: smallSamples)
        let highlightedLarge = collectHighlightedInserts(text: largeText, samples: largeSamples)

        note("  intelligence attached")
        let intelligenceSmall = collectIntelligenceInserts(text: smallText, samples: smallSamples)
        let intelligenceLarge = collectIntelligenceInserts(text: largeText, samples: largeSamples)

        note("  typing with popup")
        let popupSmall = collectPopupInserts(text: smallText, samples: smallSamples)
        let popupLarge = collectPopupInserts(text: largeText, samples: largeSamples)
        let popupNoDocsLarge = collectPopupInserts(text: largeText, samples: largeSamples, documentation: false)

        note("  typing while indexing")
        let duringIndexSmall = collectInsertsWhileIndexing(on: smallView, samples: smallSamples)
        let duringIndexLarge = collectInsertsWhileIndexing(on: largeView, samples: largeSamples)

        note("  completion, diagnostics, index query")
        let intelligence = try awaitIntelligence()

        note("  memory")
        let memory = memoryObservation(on: largeView)

        note("  cpu")
        let cpu = cpuObservation(on: smallView)

        note("  frame")
        let frame = measurePresentedFrame()

        emit(stage: "insert", band: "small", samples: small.insert)
        emit(stage: "delete", band: "small", samples: small.delete)
        emit(stage: "paste", band: "small", samples: small.paste)
        emit(stage: "multi_cursor", band: "small", samples: small.multiCursor)
        emit(stage: "selection", band: "small", samples: small.selection)
        emit(stage: "undo", band: "small", samples: small.undo)
        emit(stage: "redo", band: "small", samples: small.redo)
        emit(stage: "cursor_movement", band: "small", samples: small.cursorMovement)
        emit(stage: "text_mutation", band: "small", samples: small.textMutation)
        emit(stage: "caret", band: "small", samples: small.caret)
        emit(stage: "visible_update", band: "small", samples: small.visibleUpdate)
        emit(stage: "main_thread", band: "small", samples: small.mainThread)

        emit(stage: "insert", band: "large", samples: large.insert)
        emit(stage: "delete", band: "large", samples: large.delete)
        emit(stage: "paste", band: "large", samples: large.paste)
        emit(stage: "multi_cursor", band: "large", samples: large.multiCursor)
        emit(stage: "selection", band: "large", samples: large.selection)
        emit(stage: "undo", band: "large", samples: large.undo)
        emit(stage: "redo", band: "large", samples: large.redo)
        emit(stage: "cursor_movement", band: "large", samples: large.cursorMovement)
        emit(stage: "text_mutation", band: "large", samples: large.textMutation)
        emit(stage: "caret", band: "large", samples: large.caret)
        emit(stage: "visible_update", band: "large", samples: large.visibleUpdate)
        emit(stage: "main_thread", band: "large", samples: large.mainThread)

        emit(stage: "incremental_parse", band: "highlighted_small", samples: highlightedSmall.incrementalParse)
        emit(stage: "incremental_parse", band: "highlighted_large", samples: highlightedLarge.incrementalParse)
        emit(stage: "insert", band: "highlighted_small", samples: highlightedSmall.insert)
        emit(stage: "insert", band: "highlighted_large", samples: highlightedLarge.insert)
        emit(stage: "visible_update", band: "highlighted_small", samples: highlightedSmall.visibleUpdate)
        emit(stage: "visible_update", band: "highlighted_large", samples: highlightedLarge.visibleUpdate)

        emit(stage: "typing_with_intelligence", band: "small", samples: intelligenceSmall.insert)
        emit(stage: "typing_with_intelligence", band: "large", samples: intelligenceLarge.insert)
        emit(stage: "completion_prepare", band: "small", samples: intelligenceSmall.completionPrepare)
        emit(stage: "completion_prepare", band: "large", samples: intelligenceLarge.completionPrepare)
        emit(stage: "text_mutation", band: "intelligence_large", samples: intelligenceLarge.textMutation)
        emit(stage: "main_thread", band: "intelligence_large", samples: intelligenceLarge.mainThread)

        emit(stage: "typing_with_popup", band: "small", samples: popupSmall)
        emit(stage: "typing_with_popup", band: "large", samples: popupLarge)
        emit(stage: "typing_with_popup", band: "large_no_documentation", samples: popupNoDocsLarge)
        emit(stage: "typing_during_background", band: "indexing_small", samples: duringIndexSmall)
        emit(stage: "typing_during_background", band: "indexing_large", samples: duringIndexLarge)

        emit(stage: "completion", band: "local", samples: intelligence.localCompletion)
        emit(stage: "completion", band: "indexed", samples: intelligence.indexedCompletion)
        emit(stage: "diagnostics", band: "duplicate_symbol", samples: intelligence.diagnostics)
        emit(stage: "index_query", band: "prefix", samples: intelligence.indexQuery)

        print("note semantic_completion see=java-completion")
        print(
            "memory rss_before_bytes=\(memory.rssBefore) rss_after_bytes=\(memory.rssAfter) rss_delta_bytes=\(memory.rssDelta) allocation_before_bytes=\(memory.allocationBefore) allocation_after_bytes=\(memory.allocationAfter) allocation_delta_bytes=\(memory.allocationDelta)"
        )
        print(
            "cpu typing_batch_wall_s=\(format(cpu.wall)) typing_batch_cpu_s=\(format(cpu.cpu)) samples=\(cpu.samples)"
        )
        let smallInsert = LatencyDistributionReducer.reduce(small.insert)
        let largeInsert = LatencyDistributionReducer.reduce(large.insert)
        print(
            "band small_idle_insert_median_s=\(format(smallInsert.median)) large_insert_median_s=\(format(largeInsert.median)) large_insert_worst_s=\(format(largeInsert.worst)) small_idle_insert_worst_s=\(format(smallInsert.worst))"
        )

        if let failure = frame.failure {
            print("frame_presentation launcher_failure \(failure)")
        } else if let seconds = frame.seconds {
            print("stage frame presented count=1 median_s=\(format(seconds)) p95_s=\(format(seconds)) p99_s=\(format(seconds)) worst_s=\(format(seconds))")
            print("dropped_frames count=\(frame.droppedFrames)")
        }

        budget("text_mutation", target: 0.001, samples: small.textMutation)
        budget("cursor_movement", target: 0.001, samples: small.cursorMovement)
        budget("incremental_parse", target: 0.005, samples: highlightedSmall.incrementalParse)
        budget("visible_update", target: 0.016, samples: small.visibleUpdate)
        budget("typing_with_popup_large", target: 0.016, samples: popupLarge)
        budget("completion_local", target: 0.030, samples: intelligence.localCompletion)
        budget("completion_indexed", target: 0.050, samples: intelligence.indexedCompletion)
        budget("indexed_navigation", target: 0.050, samples: intelligence.indexQuery)
        budget("diagnostics", target: 0.100, samples: intelligence.diagnostics)

        let worst: [String: Double] = [
            "insert_small": smallInsert.worst,
            "insert_large": largeInsert.worst,
            "text_mutation_small": LatencyDistributionReducer.reduce(small.textMutation).worst,
            "text_mutation_large": LatencyDistributionReducer.reduce(large.textMutation).worst,
            "visible_update_small": LatencyDistributionReducer.reduce(small.visibleUpdate).worst,
            "visible_update_large": LatencyDistributionReducer.reduce(large.visibleUpdate).worst,
            "visible_update_highlighted_large": LatencyDistributionReducer.reduce(highlightedLarge.visibleUpdate).worst,
            "typing_with_intelligence_small": LatencyDistributionReducer.reduce(intelligenceSmall.insert).worst,
            "typing_with_intelligence_large": LatencyDistributionReducer.reduce(intelligenceLarge.insert).worst,
            "typing_during_background_small": LatencyDistributionReducer.reduce(duringIndexSmall).worst,
            "typing_during_background_large": LatencyDistributionReducer.reduce(duringIndexLarge).worst
        ]
        let freezes = EditorPerformanceGuard.grossFreezes(worst)
        if freezes.isEmpty {
            print("freeze_check result=pass threshold_s=\(format(EditorPerformanceGuard.grossFreezeSeconds))")
        } else {
            let message = "freeze_check result=fail stages=\(freezes.joined(separator: ",")) threshold_s=\(format(EditorPerformanceGuard.grossFreezeSeconds))"
            print(message)
            throw ProfileFreeze(message: message)
        }

        if EditorPerformanceDashboard.isEnabled() {
            let frameSeconds = frame.seconds ?? 0
            let text = EditorPerformanceDashboard.render(
                frameSeconds: frameSeconds,
                textMutationSeconds: LatencyDistributionReducer.reduce(small.textMutation).median,
                incrementalParseSeconds: LatencyDistributionReducer.reduce(highlightedSmall.incrementalParse).median,
                completionSeconds: LatencyDistributionReducer.reduce(intelligence.localCompletion).median,
                diagnosticsSeconds: LatencyDistributionReducer.reduce(intelligence.diagnostics).median,
                indexQuerySeconds: LatencyDistributionReducer.reduce(intelligence.indexQuery).median,
                mainThreadSeconds: LatencyDistributionReducer.reduce(small.mainThread).median,
                droppedFrames: frame.droppedFrames,
                memoryBytes: memory.rssAfter
            )
            if let path = ProcessInfo.processInfo.environment[EditorPerformanceDashboard.pathEnvironmentVariable] {
                try text.write(toFile: path, atomically: true, encoding: .utf8)
                note("  wrote performance dashboard to \(path)")
            }
        }
    }

    // MARK: - Editing

    private static func collectEditingOperations(on textView: TextView, samples: Int) -> Samples {
        var collected = Samples()
        let pasted = String(repeating: "pasted text ", count: 20)
        for _ in 0..<samples {
            placeCaret(in: textView, fraction: 0.5)
            let inserted = timedMutation(on: textView) {
                textView.insertText("x")
            }
            collected.insert.append(inserted.wall)
            collected.textMutation.append(inserted.mutation)
            collected.caret.append(inserted.caret)
            collected.incrementalParse.append(inserted.parse)
            collected.visibleUpdate.append(inserted.visible)
            collected.mainThread.append(inserted.main)
            collected.completionPrepare.append(inserted.prepare)

            placeCaret(in: textView, fraction: 0.5)
            let deleted = timedMutation(on: textView) {
                textView.deleteBackward()
            }
            collected.delete.append(deleted.wall)

            placeCaret(in: textView, fraction: 0.4)
            let paste = timedMutation(on: textView) {
                let location = textView.selectedRange.location
                textView.replace(NSRange(location: location, length: 0), withText: pasted)
            }
            collected.paste.append(paste.wall)

            let multi = timedMutation(on: textView) {
                applyMultiCursorInsert(on: textView)
            }
            collected.multiCursor.append(multi.wall)

            let selected = seconds {
                let location = min(10, textView.documentLength)
                let length = min(24, max(textView.documentLength - location, 0))
                textView.selectedRange = NSRange(location: location, length: length)
            }
            collected.selection.append(selected)

            let origin = textView.selectedRange.location
            let moved = seconds {
                let next = origin + 1 < textView.documentLength ? origin + 1 : max(origin - 1, 0)
                textView.selectedRange = NSRange(location: next, length: 0)
            }
            collected.cursorMovement.append(moved)

            textView.insertText("u")
            let undone = seconds {
                textView.undoManager?.undo()
            }
            collected.undo.append(undone)
            let redone = seconds {
                textView.undoManager?.redo()
            }
            collected.redo.append(redone)
        }
        return collected
    }

    private static func collectHighlightedInserts(text: String, samples: Int) -> Samples {
        guard let language = TreeSitterLanguage.bundled(forIdentifier: "javascript") else {
            print("incremental_parse launcher_failure language=javascript unavailable")
            return Samples()
        }
        let textView = makeTextView(text: text, language: language)
        note("  syntax tree ready=\(textView.isSyntaxTreeReady) lines=\(textView.lineCount)")
        warmUp(textView)
        var collected = Samples()
        for _ in 0..<samples {
            placeCaret(in: textView, fraction: 0.5)
            let inserted = timedMutation(on: textView) {
                textView.insertText("x")
            }
            collected.insert.append(inserted.wall)
            collected.incrementalParse.append(inserted.parse)
            collected.visibleUpdate.append(inserted.visible)
            collected.textMutation.append(inserted.mutation)
        }
        return collected
    }

    private static func collectIntelligenceInserts(text: String, samples: Int) -> Samples {
        let textView = makeTextView(text: text, language: nil)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [EmptyCompletionProvider()], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )
        waitForDocument(controller)
        warmUp(textView)
        var collected = Samples()
        for index in 0..<samples {
            placeCaret(in: textView, fraction: 0.5)
            let inserted = timedMutation(on: textView) {
                textView.insertText(index.isMultiple(of: 2) ? "a" : "b")
            }
            collected.insert.append(inserted.wall)
            collected.textMutation.append(inserted.mutation)
            collected.completionPrepare.append(inserted.prepare)
            collected.mainThread.append(inserted.main)
            collected.visibleUpdate.append(inserted.visible)
        }
        withExtendedLifetime(controller) {}
        return collected
    }

    /// Keystrokes while the completion popup is open (items from every request, a hover
    /// provider for the documentation preview), so everything the popup does per keystroke on
    /// the main thread is inside the measured insert.
    private static func collectPopupInserts(text: String, samples: Int, documentation: Bool = true) -> [Double] {
        let textView = makeTextView(text: text, language: nil)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [FixedCompletionProvider()], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: [FixedHoverProvider()]),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )
        controller.showsCompletionDocumentation = documentation
        waitForDocument(controller)
        warmUp(textView)
        placeCaret(in: textView, fraction: 0.5)
        textView.insertText(" v")
        let deadline = Date().addingTimeInterval(2)
        while !controller.isShowingCompletion && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        var walls: [Double] = []
        for index in 0..<samples {
            // Typing and deleting one letter keeps the prefix matching (`va` / `v`), so the popup
            // stays open for every sample.
            let inserted = timedMutation(on: textView) {
                if index.isMultiple(of: 2) { textView.insertText("a") } else { textView.deleteBackward() }
            }
            walls.append(inserted.wall)
            // Let the popup refresh and the documentation preview resolve between keystrokes.
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        if !controller.isShowingCompletion { note("  popup closed during typing_with_popup; samples still recorded") }
        withExtendedLifetime(controller) {}
        return walls
    }

    private static func collectInsertsWhileIndexing(on textView: TextView, samples: Int) -> [Double] {
        let flag = StopFlag()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let index = SymbolIndex()
            let documentID = DocumentID()
            let range = zeroRange()
            var generation = 0
            while !flag.isStopped {
                var symbols: [Symbol] = []
                symbols.reserveCapacity(1_500)
                for offset in 0..<1_500 {
                    symbols.append(Symbol(
                        name: "indexed\(offset)g\(generation)",
                        kind: .function,
                        documentID: documentID,
                        range: range
                    ))
                }
                await index.index(symbols, for: documentID)
                _ = await index.search(prefix: "indexed")
                generation += 1
            }
            done.signal()
        }
        var walls: [Double] = []
        for _ in 0..<samples {
            placeCaret(in: textView, fraction: 0.35)
            let inserted = timedMutation(on: textView) {
                textView.insertText("q")
            }
            walls.append(inserted.wall)
        }
        flag.stop()
        _ = done.wait(timeout: .now() + 15)
        return walls
    }

    // MARK: - Intelligence off the keystroke

    private struct IntelligenceSamples {
        var localCompletion: [Double] = []
        var indexedCompletion: [Double] = []
        var diagnostics: [Double] = []
        var indexQuery: [Double] = []
    }

    private static func awaitIntelligence() throws -> IntelligenceSamples {
        let box = ResultBox<IntelligenceSamples>()
        Task { @MainActor in
            do {
                box.result = .success(try await measureIntelligence())
            } catch {
                box.result = .failure(error)
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while box.result == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let result = box.result else {
            throw ProfileFreeze(message: "intelligence profile timed out")
        }
        return try result.get()
    }

    private static func measureIntelligence() async throws -> IntelligenceSamples {
        var collected = IntelligenceSamples()
        let documentID = DocumentID()
        let range = zeroRange()
        let index = SymbolIndex()
        var symbols: [Symbol] = []
        let words = ["value", "variable", "vector", "valid", "vault", "velocity"]
        for word in words {
            symbols.append(Symbol(name: word, kind: .word, documentID: documentID, range: range))
        }
        for offset in 0..<800 {
            symbols.append(Symbol(name: "name\(offset)", kind: .function, documentID: documentID, range: range))
        }
        symbols.append(Symbol(name: "duplicated", kind: .function, documentID: documentID, range: range))
        symbols.append(Symbol(name: "duplicated", kind: .function, documentID: documentID, range: range))
        await index.index(symbols, for: documentID)

        let localEngine = CompletionEngine(
            providers: [WordCompletionProvider(index: index)],
            debounceInterval: 0
        )
        let localContext = completionContext(prefix: "va")
        for _ in 0..<12 {
            let before = sampleCount(.completion)
            _ = try await localEngine.complete(context: localContext)
            collected.localCompletion.append(consume(.completion, since: before))
        }

        let indexedEngine = CompletionEngine(
            providers: [SymbolCompletionProvider(index: index)],
            debounceInterval: 0
        )
        let indexedContext = completionContext(prefix: "na")
        for _ in 0..<12 {
            let before = sampleCount(.completion)
            _ = try await indexedEngine.complete(context: indexedContext)
            collected.indexedCompletion.append(consume(.completion, since: before))
        }

        let diagnostics = DiagnosticEngine(providers: [DuplicateSymbolDiagnosticProvider(index: index)])
        let document = Document(
            id: documentID,
            displayName: "profile",
            contentSnapshot: TextSnapshot(version: 1, text: "duplicated duplicated"),
            selection: Selection(range: range),
            cursor: Cursor(position: range.start),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600)
        )
        for _ in 0..<12 {
            let before = sampleCount(.diagnostics)
            _ = await diagnostics.diagnostics(for: document)
            collected.diagnostics.append(consume(.diagnostics, since: before))
        }

        for _ in 0..<20 {
            let before = sampleCount(.indexQuery)
            _ = await index.search(prefix: "na")
            collected.indexQuery.append(consume(.indexQuery, since: before))
        }
        return collected
    }

    // MARK: - Memory, CPU, frame

    private struct MemoryObservation {
        var rssBefore: UInt64
        var rssAfter: UInt64
        var rssDelta: Int64
        var allocationBefore: UInt64
        var allocationAfter: UInt64
        var allocationDelta: Int64
    }

    private static func memoryObservation(on textView: TextView) -> MemoryObservation {
        let rssBefore = Measurement.residentMemoryBytes()
        let allocationBefore = Measurement.mallocBytesInUse()
        for _ in 0..<40 {
            placeCaret(in: textView, fraction: 0.5)
            textView.insertText("m")
        }
        let rssAfter = Measurement.residentMemoryBytes()
        let allocationAfter = Measurement.mallocBytesInUse()
        return MemoryObservation(
            rssBefore: rssBefore,
            rssAfter: rssAfter,
            rssDelta: Int64(rssAfter) - Int64(rssBefore),
            allocationBefore: allocationBefore,
            allocationAfter: allocationAfter,
            allocationDelta: Int64(allocationAfter) - Int64(allocationBefore)
        )
    }

    private struct CPUObservation {
        var wall: Double
        var cpu: Double
        var samples: Int
    }

    private static func cpuObservation(on textView: TextView) -> CPUObservation {
        let samples = 20
        let cpuBefore = Measurement.threadCPUSeconds()
        let wall = seconds {
            for _ in 0..<samples {
                placeCaret(in: textView, fraction: 0.5)
                textView.insertText("c")
                textView.layoutSubviews()
            }
        }
        let cpuAfter = Measurement.threadCPUSeconds()
        return CPUObservation(wall: wall, cpu: max(0, cpuAfter - cpuBefore), samples: samples)
    }

    private struct FrameObservation {
        var seconds: Double?
        var droppedFrames: Int
        var failure: String?
    }

    private static func measurePresentedFrame() -> FrameObservation {
        let textView = makeTextView(text: generatedSource(lineCount: 120), language: nil)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        textView.isMetalRenderingEnabled = true
        textView.layoutSubviews()
        Measurement.pumpRunLoop(seconds: 0.25)
        guard textView.isMetalRenderingActive else {
            return FrameObservation(
                seconds: nil,
                droppedFrames: 0,
                failure: "Metal is not active (no device, headless window server, or PenumbraMetalRendering kill switch)"
            )
        }
        var loopSeconds: [Double] = []
        let scrollable = max(textView.contentSize.height - textView.frame.height, 1)
        for index in 0..<12 {
            textView.contentOffset = CGPoint(x: 0, y: scrollable * Double(index) / 11)
            let sample = seconds {
                textView.layoutSubviews()
                Measurement.pumpRunLoop(seconds: 0.02)
            }
            loopSeconds.append(sample)
        }
        let drawNanos = textView.metalPerformanceStats?.drawNanosP95 ?? 0
        guard drawNanos > 0 else {
            return FrameObservation(
                seconds: nil,
                droppedFrames: 0,
                failure: "Metal canvas was active but no frame time was presented"
            )
        }
        let dropped = loopSeconds.filter { $0 >= (1.0 / 30.0) }.count
        return FrameObservation(seconds: drawNanos / 1_000_000_000, droppedFrames: dropped, failure: nil)
    }

    // MARK: - Primitives

    private struct MutationCost {
        var wall: Double
        var mutation: Double
        var caret: Double
        var parse: Double
        var visible: Double
        var main: Double
        var prepare: Double
    }

    private static func timedMutation(on textView: TextView, _ body: () -> Void) -> MutationCost {
        let mutationCount = sampleCount(.textMutation)
        let caretCount = sampleCount(.caret)
        let parseCount = sampleCount(.incrementalParse)
        let layoutCount = sampleCount(.visibleLayout)
        let prepareCount = sampleCount(.completionPrepare)
        let edit = seconds(body)
        let layout = seconds {
            textView.layoutSubviews()
        }
        let syncLayout = consume(.visibleLayout, since: layoutCount)
        return MutationCost(
            wall: edit + layout,
            mutation: consume(.textMutation, since: mutationCount),
            caret: consume(.caret, since: caretCount),
            parse: consume(.incrementalParse, since: parseCount),
            visible: syncLayout + layout,
            main: edit + layout,
            prepare: consume(.completionPrepare, since: prepareCount)
        )
    }

    private static func applyMultiCursorInsert(on textView: TextView) {
        let length = textView.documentLength
        guard length > 30 else {
            textView.insertText("m")
            return
        }
        let points = [length / 5, length / 2, (length * 4) / 5]
        textView.selectedRanges = points.map { NSRange(location: $0, length: 0) }
        textView.insertText("m")
    }

    private static func warmUp(_ textView: TextView) {
        for _ in 0..<2 {
            placeCaret(in: textView, fraction: 0.5)
            textView.insertText("w")
            textView.layoutSubviews()
        }
    }

    private static func placeCaret(in textView: TextView, fraction: Double) {
        let length = textView.documentLength
        let location = min(max(0, Int(Double(length) * fraction)), max(length, 0))
        textView.selectedRange = NSRange(location: min(location, length), length: 0)
    }

    private static func makeTextView(text: String, language: TreeSitterLanguage?) -> TextView {
        let state: TextViewState
        if let language {
            state = TextViewState(text: text, language: language, parsePolicy: .eager)
        } else {
            state = TextViewState(text: text)
        }
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        textView.setState(state)
        textView.layoutSubviews()
        return textView
    }

    private static func waitForDocument(_ controller: EditorIntelligenceController) {
        let deadline = Date().addingTimeInterval(2)
        while controller.adapter.currentDocument == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func generatedSource(lineCount: Int) -> String {
        var lines: [String] = []
        lines.reserveCapacity(lineCount + 2)
        lines.append("function compute(n) {")
        for index in 0..<lineCount {
            lines.append("  var value\(index % 120) = value\((index + 7) % 120) + \(index);")
        }
        lines.append("  return value0;")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
    }

    private static func sampleCount(_ stage: EditorPerformanceStage) -> Int {
        EditorPerformanceTrace.shared.samples(for: stage).count
    }

    private static func consume(_ stage: EditorPerformanceStage, since count: Int) -> Double {
        let samples = EditorPerformanceTrace.shared.samples(for: stage)
        guard count < samples.count else { return 0 }
        return samples[count...].reduce(0, +)
    }

    private static func emit(stage: String, band: String, samples: [Double]) {
        let distribution = LatencyDistributionReducer.reduce(samples)
        print(
            "stage \(stage) \(band) count=\(distribution.count) median_s=\(format(distribution.median)) p95_s=\(format(distribution.p95)) p99_s=\(format(distribution.p99)) worst_s=\(format(distribution.worst))"
        )
    }

    private static func budget(_ name: String, target: Double, samples: [Double]) {
        let median = LatencyDistributionReducer.reduce(samples).median
        let result = median <= target ? "pass" : "miss"
        print("budget \(name) target_s=\(format(target)) median_s=\(format(median)) result=\(result)")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.9f", value)
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write("\(text)\n".data(using: .utf8)!)
    }

    private nonisolated static func zeroRange() -> EditorIntelligence.TextRange {
        let position = EditorIntelligence.TextPosition(line: 0, column: 0, utf16Offset: 0)
        return EditorIntelligence.TextRange(start: position, end: position)
    }

    private static func completionContext(prefix: String) -> CompletionContext {
        let position = EditorIntelligence.TextPosition(line: 0, column: prefix.utf16.count, utf16Offset: prefix.utf16.count)
        let range = EditorIntelligence.TextRange(start: position, end: position)
        let document = Document(
            displayName: "profile",
            contentSnapshot: TextSnapshot(version: 1, text: prefix),
            selection: Selection(range: range),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
            languageIdentifier: "javascript"
        )
        return CompletionContext(
            document: document,
            cursor: document.cursor,
            trigger: .manual,
            prefix: prefix,
            range: range
        )
    }
}

private struct EmptyCompletionProvider: CompletionProvider {
    let name = "profile-empty"

    func provide(context: CompletionContext) async -> [CompletionItem] {
        []
    }
}

/// Items for every request, so the popup stays open while the profile types.
private struct FixedCompletionProvider: CompletionProvider {
    let name = "profile-fixed"

    func provide(context: CompletionContext) async -> [CompletionItem] {
        ["value", "valid", "vault", "variable", "vector", "velocity"].map {
            CompletionItem(label: $0, insertText: $0, kind: .variable, range: context.range, source: name)
        }
    }
}

private struct FixedHoverProvider: HoverProvider {
    let name = "profile-hover"

    func provide(context: HoverContext) async -> HoverResult? {
        HoverResult(contents: "**documentation** for the selected item", source: name)
    }
}

private struct ProfileFreeze: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

private final class ResultBox<Value>: @unchecked Sendable {
    var result: Result<Value, Error>?
}
