import AppKit
import EditorIntelligence
@_spi(Benchmarks) import JavaIntelligence
import Penumbra

/// What a developer waits for: a character typed into a real `TextView` hosted in a window, a real
/// `EditorIntelligenceController`, the `CompletionEngine` with the providers Umbra registers (Symbol,
/// Word, Snippet, Java) and its default 50 ms debounce, up to the first `draw` of the popup. Every
/// sample is read from ``CompletionLatencyTrace``, so each boundary is a measured one.
///
///   swift run -c release PerfHarness java-completion-latency synthetic [--lines N] [--per-class N] [--unicode] [--samples N]
///   swift run -c release PerfHarness java-completion-latency project <name> [--samples N]
///
/// `project` reads Umbra's own cached Gradle model for `<name>` (the last path component of a project
/// root it has synced) and indexes exactly what `IDEJavaSupport` does: project source shards at
/// precedence 1, dependency jars at 2, the JDK at 3, completion scoped to the source set. It never runs
/// Gradle and writes only to a temporary directory. Without a cached model the folder is indexed whole.
///
/// The keystroke is `TextView.insertText`: it starts at the text mutation, not at the key press, so the
/// time the window server and the run loop take to deliver a real key event is not in these numbers.
/// The last boundary is the popup's first `draw`; whether the compositor has put that frame on the
/// screen is not measured.
@MainActor
enum CompletionLatencyProfile {
    /// Seconds between the characters of one typed word. A person types about five to ten characters a
    /// second; `--burst` types a character every 10 ms, which the engine treats as one burst.
    private static var typingInterval: TimeInterval = 0.15
    /// Gaps of more than 5 ms between two ticks of a 1 ms main-run-loop timer: stretches where the main thread
    /// was busy or blocked. Read per request by ``record``. Off unless `--stalls` is given.
    nonisolated(unsafe) private static var stalls: [(start: UInt64, milliseconds: Double)] = []
    nonisolated(unsafe) private static var heartbeat: Timer?
    nonisolated(unsafe) private static var lastTick: UInt64 = 0

    private static func startHeartbeat() {
        lastTick = CompletionLatencyTrace.now()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { _ in
            let now = CompletionLatencyTrace.now()
            let gap = Double(now &- lastTick) / 1e6
            if gap > 5 { stalls.append((lastTick, gap)) }
            lastTick = now
        }
    }

    // MARK: - Entry

    static func run(arguments: [String]) throws {
        let samples = Int(flagValue("--samples", in: arguments) ?? "") ?? 12
        typingInterval = hasFlag("--burst", in: arguments) ? 0.01 : 0.15
        CompletionLatencyTrace.setEnabled(true, printingSummaries: hasFlag("--timelines", in: arguments))
        JavaCompletionStageTimer.enable(true)
        defer {
            CompletionLatencyTrace.setEnabled(false)
            JavaCompletionStageTimer.enable(false)
        }
        if hasFlag("--stalls", in: arguments) { startHeartbeat() }
        if arguments.first == "save" {
            try runSave(arguments: Array(arguments.dropFirst()), saves: Int(flagValue("--saves", in: arguments) ?? "") ?? 6)
        } else if arguments.first == "project" {
            guard arguments.count > 1 else { throw LatencyFailure(message: "java-completion-latency project <name>") }
            try runProject(name: arguments[1], samples: samples, fileCount: Int(flagValue("--files", in: arguments) ?? "") ?? 2)
        } else {
            try runSynthetic(
                lines: Int(flagValue("--lines", in: arguments) ?? "") ?? 20_000,
                perClass: Int(flagValue("--per-class", in: arguments) ?? "") ?? 100,
                unicode: hasFlag("--unicode", in: arguments),
                samples: samples
            )
        }
    }

    // MARK: - Synthetic

    private static func runSynthetic(lines: Int, perClass: Int, unicode: Bool, samples: Int) throws {
        let setup = try blocking { try await JavaCompletionProfile.prepareIndex(jars: 0) }
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        JavaCompletionProfile.fillerPerClass = perClass
        JavaCompletionProfile.unicodeHeader = unicode
        let provider = JavaCompletionProvider(index: setup.index)
        let methods = lines / 5
        let url = setup.directory.appendingPathComponent("Completing.java")
        func source(statement: String) -> String {
            """
            \(JavaCompletionProfile.header)package com.perf.app;

            import com.perf.p0.*;
            import java.util.*;
            import java.util.stream.*;

            class Completing {
            \(JavaCompletionProfile.filler(methods))
                void test(User user, List<User> users) {
                    \(statement)
                }
            }
            """
        }
        let label = "\(lines) lines, \(perClass == 0 ? "one class" : "classes of \(perClass)"), \(unicode ? "non-ASCII" : "ASCII")"
        print("=== java completion latency: synthetic \(label), samples=\(samples), \(Int(typingInterval * 1000)) ms between typed characters ===")

        // `user.getAddress().` : the dot is removed from the text and typed.
        let dotText = source(statement: "user.getAddress()")
        let dotOffset = (dotText as NSString).range(of: "user.getAddress()").upperBound
        measure(
            "\(label)", scenario: "member access after '.'", text: dotText, url: url, provider: provider, samples: samples,
            sites: [Site(offset: dotOffset, typed: ".", kind: .typeCharacter)]
        )
        // `user.ge`: the dot opens the popup, then letters update it (postfix templates need a typed prefix).
        let prefixText = source(statement: "user")
        let prefixOffset = (prefixText as NSString).range(of: "user\n").location + 4
        measure(
            "\(label)", scenario: "member access, '.' then 'g' then 'e'", text: prefixText, url: url, provider: provider, samples: samples,
            sites: [Site(offset: prefixOffset, typed: ".ge", kind: .typeCharacter)]
        )
        // `na` typed at a statement: the first letter opens the popup, the second updates it.
        let identifierText = source(statement: "")
        let identifierOffset = (identifierText as NSString).range(of: "void test(User user, List<User> users) {\n        ").upperBound
        measure(
            "\(label)", scenario: "identifier at a statement ('n' then 'a')", text: identifierText, url: url, provider: provider, samples: samples,
            sites: [Site(offset: identifierOffset, typed: "na", kind: .typeCharacter)]
        )
        // Ctrl+Space with a prefix already typed.
        let explicitText = source(statement: "us")
        let explicitOffset = (explicitText as NSString).range(of: "us\n").location + 2
        measure(
            "\(label)", scenario: "explicit completion (Ctrl+Space) after 'us'", text: explicitText, url: url, provider: provider, samples: samples,
            sites: [Site(offset: explicitOffset, typed: "", kind: .explicit)]
        )
    }

    // MARK: - Real projects

    private static func runProject(name: String, samples: Int, fileCount: Int) throws {
        let project = try ProjectEnvironment.load(named: name)
        print("=== java completion latency: project \(name) (\(project.summary)), samples=\(samples) ===")
        let provider = project.provider
        if let probe = flagValue("--probe-stub", in: CommandLine.arguments) {
            let text = try String(contentsOfFile: probe, encoding: .utf8)
            for round in 0..<6 {
                let t0 = CompletionLatencyTrace.now()
                let parsed = JavaSyntaxParser().parse(text)
                let t1 = CompletionLatencyTrace.now()
                let stubs = parsed.map { JavaSourceStubBuilder.build(tree: $0, url: URL(fileURLWithPath: probe)) }
                let t2 = CompletionLatencyTrace.now()
                print(String(format: "probe %d: parse %.2f ms, stubs %.2f ms (%d classes)", round, Double(t1 - t0) / 1e6, Double(t2 - t1) / 1e6, stubs?.classes.count ?? -1))
            }
        }
        JavaParseMemoStatistics.reset()
        var pooled: [String: Row] = [:]
        var fileTotal = 0
        for file in project.pickFiles(count: fileCount) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let found = findDotSites(in: text, count: 10)
            guard !found.isEmpty else { continue }
            let prepared = removingDots(of: found, from: text)
            let relative = file.path.replacingOccurrences(of: project.root.path + "/", with: "")
            fileTotal += 1
            let rows = measure(
                "\(name)/\(relative) (\(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines)",
                scenario: "member access after '.' at \(found.count) real sites", text: prepared.text, url: file,
                provider: provider, samples: max(2, samples / 2), sites: prepared.sites.map { Site(offset: $0.offset, typed: ".", kind: .typeCharacter) }
            )
            for (key, row) in rows {
                var total = pooled[key] ?? Row()
                total.drawn += row.drawn
                total.attempts += row.attempts
                for (milestone, values) in row.milestones { total.milestones[milestone, default: []] += values }
                for (stage, values) in row.stages { total.stages[stage, default: []] += values }
                pooled[key] = total
            }
        }
        print("\n--- \(name): pooled over \(fileTotal) files (first draw = the popup's first draw after the keystroke; provider = the Java provider's final batch) ---")
        for (key, label) in [("cold", "cold (first request in a file)"), ("moved", "caret moved"), ("warm", "warm (same place)")] {
            guard let row = pooled[key], row.attempts > 0 else { continue }
            func stat(_ milestone: String) -> String {
                guard let values = row.milestones[milestone]?.sorted(), !values.isEmpty else { return "n/a" }
                return String(format: "median %.1f p95 %.1f", values[values.count / 2], values[min(values.count - 1, Int(Double(values.count) * 0.95))])
            }
            print("  \(label): n=\(row.attempts), drawn \(row.drawn) | first draw \(stat("popup first draw")) ms | provider final \(stat("Java final batch")) ms")
        }
        let memo = JavaParseMemoStatistics.snapshot()
        print(String(format: "  parse memo (capacity 12 / 24 MB): hits %d, parses %d (hit rate %.0f%%), distinct texts %d, evictions %d, parses of text just evicted %d (%.1f ms of %.1f ms parsing), peak %.1f MB",
                     memo.hits, memo.parses, memo.hitRate * 100, memo.distinctTexts, memo.evictions, memo.avoidableParses,
                     memo.avoidableSeconds * 1000, memo.parseSeconds * 1000, Double(memo.peakBytes) / 1_048_576))
    }

    // MARK: - Save to completion

    /// What the user waits for after ⌘S: the stub shard of the saved file's source root is rebuilt (every `.java`
    /// file of the root is parsed again), its reader opened (on the main actor in Umbra), `JavaIndex.setSources`
    /// rebuilds the name tables of every source, and the next completion is asked. Mirrors
    /// `IDEJavaSupport.refreshStubs`. Provider-level: "first suggestions" here is the provider's first update, not
    /// a popup draw (the popup path is measured by the other modes).
    private static func runSave(arguments: [String], saves: Int) throws {
        let mode = arguments.first ?? "synthetic"
        let setup: SaveSetup
        if mode == "project" {
            guard arguments.count > 1 else { throw LatencyFailure(message: "java-completion-latency save project <name>") }
            setup = try SaveSetup.project(named: arguments[1], variants: arguments)
        } else {
            setup = try blocking {
                try await SaveSetup.synthetic(
                    modules: Int(flagValue("--modules", in: arguments) ?? "") ?? 1,
                    filesPerModule: Int(flagValue("--files", in: arguments) ?? "") ?? 1_000,
                    jars: Int(flagValue("--jars", in: arguments) ?? "") ?? 100,
                    activeLines: Int(flagValue("--large-lines", in: arguments) ?? "") ?? 0
                )
            }
        }
        let variant: SaveSetup.Variant = hasFlag("--syntax-error", in: arguments) ? .syntaxError
            : hasFlag("--unchanged", in: arguments) ? .unchanged : .edited
        print("=== java save to completion: \(setup.summary); the saved root has \(setup.rootFileCount) .java files; variant \(variant), saves=\(saves) ===")
        let report = try blocking { await setup.measure(saves: saves, variant: variant) }
        func line(_ name: String, _ values: [Double]) {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return }
            print(String(format: "  %-52@ median %8.1f ms   p95 %8.1f ms   (n=%d)", name as NSString, sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.count))
        }
        line("completion before the save (warm)", report.baseline)
        line("stub shard rebuilt (parse of the whole root)", report.indexing)
        line("reader opened (main actor in Umbra)", report.reader)
        line("JavaIndex.setSources (all sources' name tables)", report.setSources)
        line("completion asked while setSources runs: latency", report.during)
        line("completion right after the publish (first, caches cold)", report.after)
        line("completion after that (second)", report.afterSecond)
        line("save until the new sources are in effect (sum of the three)", zip(report.indexing, zip(report.reader, report.setSources)).map { $0.0 + $0.1.0 + $0.1.1 })
    }

    // MARK: - Measuring

    private struct Site {
        enum Kind { case typeCharacter, explicit }
        let offset: Int
        let typed: String
        let kind: Kind
    }

    private struct Row {
        var drawn = 0
        var attempts = 0
        var milestones: [String: [Double]] = [:]
        var holds = 0
        var holdReleases = 0
        var superseded = 0
        var items: [Int] = []
        /// Milliseconds the Java provider spent in each stage of its request (`JavaCompletionStageTimer`).
        var stages: [String: [Double]] = [:]
    }

    @discardableResult
    private static func measure(
        _ title: String, scenario: String, text: String, url: URL, provider: JavaCompletionProvider, samples: Int, sites: [Site]
    ) -> [String: Row] {
        let (window, textView) = makeTextView(text: text, url: url)
        let symbols = SymbolIndex()
        let engine = CompletionEngine(providers: [
            SymbolCompletionProvider(index: symbols), WordCompletionProvider(index: symbols), SnippetCompletionProvider(), provider
        ])
        let controller = EditorIntelligenceController(
            textView: textView, completionEngine: engine, hoverEngine: HoverEngine(providers: []), diagnosticEngine: DiagnosticEngine(providers: [])
        )
        let deadline = Date().addingTimeInterval(3)
        while controller.adapter.currentDocument == nil, Date() < deadline { pump(0.02) }
        pump(0.3)

        // Per site, `samples` repetitions in a row. The very first request after the file was opened is the cold
        // one; the first at each later site is a request after the caret jumped somewhere else (the incremental
        // parse has to cover the distance); the repetitions are one word typed again at the same place.
        var rows: [String: Row] = ["cold": Row(), "moved": Row(), "warm": Row(), "update": Row()]
        var isFirstRequest = true
        var perSite: [(snippet: String, drawn: [Double], receiver: [Double])] = []
        for site in sites {
            let before = rows["warm"]!.milestones["popup first draw"]?.count ?? 0
            let receiverBefore = rows["warm"]!.stages["receiver"]?.count ?? 0
            for repetition in 0..<samples {
                textView.selectedRange = NSRange(location: site.offset, length: 0)
                pump(0.01)
                let firstFirstKey = isFirstRequest ? "cold" : (repetition == 0 ? "moved" : "warm")
                switch site.kind {
                case .explicit:
                    record(&rows[firstFirstKey]!, controller: controller) { controller.triggerCompletion() }
                    isFirstRequest = false
                    controller.dismissCompletion()
                case .typeCharacter:
                    let characters = Array(site.typed)
                    for (index, character) in characters.enumerated() {
                        let key = index > 0 ? "update" : firstFirstKey
                        if index > 0 { pump(typingInterval) }
                        record(&rows[key]!, controller: controller) { textView.insertText(String(character)) }
                        isFirstRequest = false
                    }
                    controller.dismissCompletion()
                    for _ in characters { textView.deleteBackward() }
                }
                pump(0.03)
            }
            if site.kind == .typeCharacter {
                let ns = text as NSString
                let start = max(0, site.offset - 44)
                let snippet = ns.substring(with: NSRange(location: start, length: site.offset - start)).replacingOccurrences(of: "\n", with: " ")
                    + "▮" + ns.substring(with: NSRange(location: site.offset, length: min(14, ns.length - site.offset))).replacingOccurrences(of: "\n", with: " ")
                let warm = rows["warm"]!
                perSite.append((
                    snippet.trimmingCharacters(in: .whitespaces),
                    Array((warm.milestones["popup first draw"] ?? []).dropFirst(before)),
                    Array((warm.stages["receiver"] ?? []).dropFirst(receiverBefore))
                ))
            }
        }
        window.orderOut(nil)
        withExtendedLifetime(controller) {}

        print("\n\(title)\n  \(scenario)")
        report("first popup, cold (first request after the file was opened)", rows["cold"]!)
        report("first popup after the caret moved to another place", rows["moved"]!)
        report("first popup, same place again (warm)", rows["warm"]!)
        report("update to an open popup", rows["update"]!)
        if perSite.count > 1 {
            print("      slowest sites (same place again, median ms to first draw; receiver typing ms):")
            for entry in perSite.filter({ !$0.drawn.isEmpty }).sorted(by: { $0.drawn.sorted()[$0.drawn.count / 2] > $1.drawn.sorted()[$1.drawn.count / 2] }).prefix(4) {
                let drawn = entry.drawn.sorted()[entry.drawn.count / 2]
                let receiver = entry.receiver.isEmpty ? 0 : entry.receiver.sorted()[entry.receiver.count / 2]
                print(String(format: "        %6.1f   %6.1f   %@", drawn, receiver, entry.snippet as NSString))
            }
        }
        return rows
    }

    /// Runs `action`, waits for the request's popup to draw (or to finish with nothing to show, or a timeout),
    /// and adds its milestones, in milliseconds after the instant just before `action`, to `row`.
    private static func record(_ row: inout Row, controller: EditorIntelligenceController, _ action: () -> Void) {
        CompletionLatencyTrace.reset()
        JavaCompletionStageTimer.reset()
        let start = CompletionLatencyTrace.now()
        action()
        row.attempts += 1
        // The request this action made: the first `scheduled` event after the reset. Events of an earlier
        // request that are still in flight carry an older id and are left out.
        func primary(_ events: [CompletionLatencyTrace.Event]) -> Int? {
            events.filter { $0.name == "scheduled" }.min { $0.nanoseconds < $1.nanoseconds }?.request
        }
        let deadline = Date().addingTimeInterval(1.5)
        var drawn = false
        var settledAt: Date?
        while Date() < deadline {
            pump(0.002)
            let all = CompletionLatencyTrace.events()
            guard let id = primary(all) else { continue }
            let names = all.filter { $0.request == id }
            let hasDraw = names.contains { $0.name == "panelDraw" }
            let hasPresented = names.contains { $0.name == "presented" }
            let finishedWithoutPopup = names.contains { $0.name == "ingest" && $0.detail.contains("finished=true") } && !hasPresented
            let superseded = names.contains { $0.name == "superseded" }
            drawn = drawn || hasDraw
            // Done once the request has presented its results and the popup has drawn; a request that
            // finished with nothing to show, or was replaced, is done as soon as that is clear.
            if hasDraw && (hasPresented || superseded) { break }
            if hasDraw && !hasPresented, settledAt == nil { settledAt = Date() }
            if let settledAt, Date().timeIntervalSince(settledAt) > 0.4 { break }
            if finishedWithoutPopup && !hasDraw {
                settledAt = settledAt ?? Date()
                if Date().timeIntervalSince(settledAt!) > 0.05 { break }
            }
            if superseded && !hasDraw { break }
        }
        let allEvents = CompletionLatencyTrace.events()
        let id = primary(allEvents)
        let events = allEvents.filter { $0.request == id }.sorted { $0.nanoseconds < $1.nanoseconds }
        if drawn { row.drawn += 1 }
        if heartbeat != nil {
            let long = stalls.filter { $0.start >= start && $0.milliseconds > 5 }
            if !long.isEmpty {
                print(String(format: "      main-thread stalls in this request: %@", long.map { String(format: "%.0f ms at +%.0f", $0.milliseconds, Double($0.start &- start) / 1e6) }.joined(separator: ", ")))
            }
            stalls.removeAll()
        }
        for (stage, seconds) in JavaCompletionStageTimer.snapshot() { row.stages[stage, default: []].append(seconds * 1000) }
        func ms(_ event: CompletionLatencyTrace.Event?) -> Double? { event.map { Double($0.nanoseconds &- start) / 1e6 } }
        func firstEvent(_ name: String, containing text: String? = nil) -> CompletionLatencyTrace.Event? {
            events.first { $0.name == name && (text == nil || $0.detail.contains(text!)) }
        }
        func put(_ key: String, _ value: Double?) {
            if let value { row.milestones[key, default: []].append(value) }
        }
        put("typed", ms(firstEvent("typed")))
        put("scheduled", ms(firstEvent("scheduled")))
        put("taskStart", ms(firstEvent("taskStart")))
        put("engineStart (after debounce)", ms(firstEvent("engineStart")))
        put("  Java: provideUpdates called", ms(firstEvent("java:called")))
        put("  Java: task running", ms(firstEvent("java:taskStart")))
        put("  Java: on the provider actor", ms(firstEvent("java:actor")))
        put("    Java: visible shards computed", ms(firstEvent("java:scopeComputed")))
        put("    Java: module visibility computed", ms(firstEvent("java:modulesComputed")))
        put("    Java: text repaired", ms(firstEvent("java:repaired")))
        put("    Java: parsed (tree, stubs)", ms(firstEvent("java:parsed")))
        put("    Java: request object built", ms(firstEvent("java:textParsed")))
        put("  Java: request built (text, parse)", ms(firstEvent("java:requestBuilt")))
        put("  Java: site classified", ms(firstEvent("java:classified")))
        put("  Java: receiver typed", ms(firstEvent("java:receiverTyped")))
        put("  Java: expected type inferred", ms(firstEvent("java:expectedTyped")))
        put("  Java: members looked up", ms(firstEvent("java:membersLooked")))
        put("  Java: member items built", ms(firstEvent("java:memberItemsBuilt")))
        put("  Java: postfix templates built", ms(firstEvent("java:postfixBuilt")))
        put("  Java: member access done", ms(firstEvent("java:memberAccessDone")))
        put("  Java: command section built", ms(firstEvent("java:commandsBuilt")))
        put("Java first batch", ms(firstEvent("provider:Java")))
        put("Java final batch", ms(firstEvent("provider:Java", containing: "finished=true")))
        put("engine first snapshot", ms(firstEvent("snapshot")))
        put("engine final snapshot", ms(firstEvent("snapshot", containing: "finished=true")))
        put("controller ingest of first snapshot", ms(firstEvent("ingest")))
        put("popup presented", ms(firstEvent("presented")))
        put("popup first draw", ms(firstEvent("panelDraw")))
        if let presented = firstEvent("presented") { _ = presented }
        row.holds += events.filter { $0.name == "ingest" && $0.detail.hasSuffix("hold") }.count
        row.holdReleases += events.filter { $0.name == "holdRelease" }.count
        row.superseded += events.filter { $0.name == "superseded" }.count
        if let presented = firstEvent("presented"), let count = Int(presented.detail.replacingOccurrences(of: "items=", with: "")) {
            row.items.append(count)
        }
    }

    private static func report(_ title: String, _ row: Row) {
        guard row.attempts > 0 else { return }
        print("  \(title): n=\(row.attempts), popup drawn \(row.drawn)/\(row.attempts), held \(row.holds), hold released \(row.holdReleases), superseded \(row.superseded)\(row.items.isEmpty ? "" : ", items median \(row.items.sorted()[row.items.count / 2])")")
        let order = [
            "typed", "scheduled", "taskStart", "engineStart (after debounce)",
            "  Java: provideUpdates called", "  Java: task running", "  Java: on the provider actor",
            "    Java: visible shards computed", "    Java: module visibility computed",
            "    Java: text repaired", "    Java: parsed (tree, stubs)", "    Java: request object built", "  Java: request built (text, parse)",
            "  Java: site classified", "  Java: receiver typed", "  Java: expected type inferred", "  Java: members looked up",
            "  Java: member items built", "  Java: postfix templates built", "  Java: member access done",
            "  Java: command section built", "Java first batch", "Java final batch",
            "engine first snapshot", "engine final snapshot", "controller ingest of first snapshot", "popup presented", "popup first draw"
        ]
        for key in order {
            guard let values = row.milestones[key], !values.isEmpty else { continue }
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
            print(String(format: "      %-38@ median %8.2f ms   p95 %8.2f ms   (n=%d)", key as NSString, median, p95, values.count))
        }
        let stages = row.stages.filter { !$0.value.isEmpty }.map { (name: $0.key, median: $0.value.sorted()[$0.value.count / 2]) }.filter { $0.median >= 0.05 }.sorted { $0.median > $1.median }
        if !stages.isEmpty {
            print("      Java provider stages (median ms): " + stages.map { String(format: "%@ %.2f", $0.name, $0.median) }.joined(separator: ", "))
        }
    }

    // MARK: - Text view

    private static func makeTextView(text: String, url: URL) -> (NSWindow, TextView) {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: frame)
        // Umbra's editor defaults that touch typing and layout.
        textView.showLineNumbers = true
        textView.isLineFoldingEnabled = true
        textView.showMinimap = !hasFlag("--no-minimap", in: CommandLine.arguments)
        textView.showMethodSeparators = true
        textView.isMetalRenderingEnabled = true
        textView.insertsClosingBraceOnEnter = true
        textView.languageIdentifier = "java"
        textView.documentURL = url
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: text, language: TreeSitterLanguage.bundled(forIdentifier: "java") ?? .java))
        textView.layoutIfNeeded()
        pump(1.0)
        if heartbeat != nil {
            let long = stalls.filter { $0.milliseconds > 5 }
            print("      main-thread stalls while the file opened (1 s): " + (long.isEmpty ? "none over 5 ms" : long.map { String(format: "%.0f ms", $0.milliseconds) }.joined(separator: ", ")))
            stalls.removeAll()
        }
        return (window, textView)
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Real sites

    private struct DotSite {
        let offset: Int
    }

    /// Evenly spread member-access dots in `text`: an identifier or `)` before the dot, a letter after it,
    /// outside imports, comments and strings.
    private static func findDotSites(in text: String, count: Int) -> [DotSite] {
        let ns = text as NSString
        var sites: [DotSite] = []
        var inBlockComment = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = ns.substring(with: range)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if trimmed.contains("*/") { inBlockComment = false }
                return
            }
            if trimmed.hasPrefix("/*") { if !trimmed.contains("*/") { inBlockComment = true }; return }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("import ") || trimmed.hasPrefix("package ") || trimmed.hasPrefix("@") { return }
            let chars = Array(line.utf16)
            var quotes = 0
            for index in 0..<chars.count {
                if chars[index] == 0x22 { quotes += 1 }
                guard chars[index] == 0x2E, quotes % 2 == 0, index > 0, index + 1 < chars.count else { continue }
                let before = chars[index - 1], after = chars[index + 1]
                let beforeOK = before == 0x29 || (before >= 0x41 && before <= 0x5A) || (before >= 0x61 && before <= 0x7A) || (before >= 0x30 && before <= 0x39) || before == 0x5F
                let afterOK = (after >= 0x41 && after <= 0x5A) || (after >= 0x61 && after <= 0x7A) || after == 0x5F
                if beforeOK, afterOK { sites.append(DotSite(offset: range.location + index)) }
            }
        }
        guard sites.count > count else { return sites }
        return (0..<count).map { sites[$0 * sites.count / count] }
    }

    /// `text` without the dots at the sites' offsets, so typing one back restores it, and the sites' offsets
    /// in that shortened text (each earlier dot removed moves a site one unit left).
    private static func removingDots(of sites: [DotSite], from text: String) -> (text: String, sites: [DotSite]) {
        let ordered = sites.sorted { $0.offset < $1.offset }
        var units = Array(text.utf16)
        for site in ordered.reversed() { units.remove(at: site.offset) }
        return (String(decoding: units, as: UTF16.self), ordered.enumerated().map { DotSite(offset: $0.element.offset - $0.offset) })
    }

    // MARK: - Blocking helper

    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }
}

struct LatencyFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - A real project's index

/// The index Umbra builds for a synced project, from its cached Gradle model: project source shards (precedence
/// 1), dependency jar shards (2), the JDK (3), with completion scoped to the file's source set. Shards go to a
/// temporary directory that is kept between runs, so the first run indexes and later ones read.
private struct ProjectEnvironment {
    let root: URL
    let provider: JavaCompletionProvider
    let files: [URL]
    let summary: String
    /// What a save needs: the index, the readers it was built from, and each source root with its shard.
    var index: JavaIndex?
    var sources: [JavaIndex.Source] = []
    var sourceRoots: [(directory: URL, shardURL: URL, shardPath: String)] = []
    var scheduler: JavaIndexScheduler?

    static func load(named name: String) throws -> ProjectEnvironment {
        let modelsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.umbra.editor/gradle-models")
        var found: JavaGradleProjectModel?
        for directory in (try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("model.json")),
                  let model = try? JSONDecoder().decode(JavaGradleProjectModel.self, from: data),
                  let rootProject = model.subprojects.first(where: { $0.path == ":" }) ?? model.subprojects.first,
                  rootProject.directory.lastPathComponent == name else { continue }
            found = model
        }
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-latency-index-v\(JavaIndexShardWriter.formatVersion)")
        let paths = JavaIndexPaths(root: cacheRoot)
        guard let jdk = JDKLocator().select() else { throw LatencyFailure(message: "needs an installed JDK") }

        var targets: [(root: any JavaIndexableRoot, shardURL: URL)] = []
        var projectShards: [(URL, String?)] = []
        let root: URL
        var files: [URL] = []
        var summary: String
        if let model = found {
            root = (model.subprojects.first(where: { $0.path == ":" }) ?? model.subprojects[0]).directory
            let sourceTargets = model.sourceIndexTargets(paths: paths)
            let jarTargets = model.jarIndexTargets(paths: paths)
            targets = sourceTargets + jarTargets
            summary = "cached Gradle model: \(model.subprojects.count) subprojects, \(sourceTargets.count) source shards, \(jarTargets.count) jars"
            for subproject in model.subprojects {
                for set in subproject.sourceSets where set.name == "main" {
                    for directory in set.sourceDirs { files += javaFiles(under: directory) }
                }
            }
            projectShards = sourceTargets.map { ($0.shardURL, $0.shardURL.path) }
            let jarShards = jarTargets.map { $0.shardURL }
            let started = Date()
            let allTargets = targets + [(root: JDKCtSymRoot(installation: jdk) as any JavaIndexableRoot, shardURL: paths.jdkShard(jdk, kind: "ctsym"))]
            try runBlocking {
                for await _ in await JavaIndexScheduler(paths: paths).index(allTargets) {}
            }
            summary += ", indexed in \(String(format: "%.1f", Date().timeIntervalSince(started))) s"
            var sources: [JavaIndex.Source] = []
            for (url, path) in projectShards { if let reader = try? JavaIndexShardReader(url: url) { sources.append(.init(precedence: 1, reader: reader, shardPath: path ?? "")) } }
            for url in jarShards { if let reader = try? JavaIndexShardReader(url: url) { sources.append(.init(precedence: 2, reader: reader, shardPath: url.path)) } }
            if let reader = try? JavaIndexShardReader(url: paths.jdkShard(jdk, kind: "ctsym")) { sources.append(.init(precedence: 3, reader: reader)) }
            let names = sources.reduce(0) { $0 + $1.reader.allQualifiedNames.count }
            summary += ", \(names) names"
            let index = JavaIndex()
            let provider = JavaCompletionProvider(index: index)
            let finalSources = sources
            try runBlocking {
                await index.setSources(finalSources)
                await provider.setSourceSetClasspath(model, indexPaths: paths)
            }
            var environment = ProjectEnvironment(root: root, provider: provider, files: files, summary: summary)
            environment.index = index
            environment.sources = finalSources
            environment.scheduler = JavaIndexScheduler(paths: paths)
            environment.sourceRoots = sourceTargets.compactMap { target in
                (target.root as? SourceRoot).map { ($0.directory, target.shardURL, target.shardURL.path) }
            }
            return environment
        }

        // No cached model: the folder is indexed whole, like Umbra before a sync.
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/\(name)")
        guard FileManager.default.fileExists(atPath: root.path) else { throw LatencyFailure(message: "no cached model and no folder ~/Developer/\(name)") }
        files = javaFiles(under: root)
        let shard = paths.projectSourcesShard(for: root)
        try runBlocking {
            for await _ in await JavaIndexScheduler(paths: paths).index([
                (root: SourceRoot(directory: root), shardURL: shard),
                (root: JDKCtSymRoot(installation: jdk), shardURL: paths.jdkShard(jdk, kind: "ctsym"))
            ]) {}
        }
        var sources: [JavaIndex.Source] = []
        if let reader = try? JavaIndexShardReader(url: shard) { sources.append(.init(precedence: 1, reader: reader)) }
        if let reader = try? JavaIndexShardReader(url: paths.jdkShard(jdk, kind: "ctsym")) { sources.append(.init(precedence: 3, reader: reader)) }
        let index = JavaIndex()
        let provider = JavaCompletionProvider(index: index)
        let finalSources = sources
        try runBlocking { await index.setSources(finalSources) }
        summary = "folder indexed whole (no cached model), \(files.count) files"
        var environment = ProjectEnvironment(root: root, provider: provider, files: files, summary: summary)
        environment.index = index
        environment.sources = finalSources
        environment.scheduler = JavaIndexScheduler(paths: paths)
        environment.sourceRoots = [(root, shard, "")]
        return environment
    }

    /// Two files of a typical size for the project: a third and two thirds of the way up its files ranked by length,
    /// among those of 80 to 1,500 lines. Deterministic, so a rerun measures the same files.
    func pickFiles(count: Int) -> [URL] {
        let sized = files.compactMap { url -> (URL, Int)? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            return (80...1_500).contains(lines) ? (url, lines) : nil
        }.sorted { ($0.1, $0.0.path) < ($1.1, $1.0.path) }
        guard !sized.isEmpty else { return [] }
        return (1...count).map { sized[min(sized.count - 1, sized.count * $0 / (count + 1))].0 }
    }

    static func javaFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "java" && !$0.path.contains("/build/") && !$0.path.contains("/generated/")
        }
    }

    private static func runBlocking(_ body: @escaping @Sendable () async -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { await body(); semaphore.signal() }
        semaphore.wait()
    }
}

// MARK: - Save to completion: the setup

/// A project (synthetic or a real one) with a file to save, enough of Umbra's index plumbing to redo what a save
/// does, and a completion request at a member access in that file.
private struct SaveSetup {
    enum Variant { case edited, syntaxError, unchanged }

    struct Report {
        var baseline: [Double] = [], indexing: [Double] = [], reader: [Double] = [], setSources: [Double] = []
        var during: [Double] = [], after: [Double] = [], afterSecond: [Double] = []
    }

    let summary: String
    let index: JavaIndex
    let provider: JavaCompletionProvider
    let scheduler: JavaIndexScheduler
    var sources: [JavaIndex.Source]
    let rootDirectory: URL
    let shardURL: URL
    let shardPath: String
    let activeFile: URL
    let activeText: String
    let dotOffset: Int
    let rootFileCount: Int
    /// Synthetic projects live in a temporary directory and are edited and saved for real. A real project's files
    /// are never written: its root is re-parsed as it is, which costs what a save of an unchanged file costs.
    var writesFile = true

    // MARK: Building

    static func synthetic(modules: Int, filesPerModule: Int, jars: Int, activeLines: Int) async throws -> SaveSetup {
        guard let jdk = JDKLocator().select() else { throw LatencyFailure(message: "needs an installed JDK") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-latency-index-v\(JavaIndexShardWriter.formatVersion)")
        let jdkPaths = JavaIndexPaths(root: cacheRoot)
        let paths = JavaIndexPaths(root: directory.appendingPathComponent("index"))
        let scheduler = JavaIndexScheduler(paths: paths)

        var roots: [(directory: URL, shardURL: URL)] = []
        for module in 0..<modules {
            let source = directory.appendingPathComponent("m\(module)/src/main/java/app\(module)", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            for file in 0..<filesPerModule {
                let text = """
                package app\(module);

                import java.util.*;

                public class C\(file) {
                    private final List<String> items = new ArrayList<>();
                    public String name() { return "c\(file)"; }
                    public int size() { return items.size(); }
                    public C\(file) with(String item) { items.add(item); return this; }
                }

                """
                try text.write(to: source.appendingPathComponent("C\(file).java"), atomically: false, encoding: .utf8)
            }
            let rootDirectory = directory.appendingPathComponent("m\(module)/src/main/java")
            roots.append((rootDirectory, paths.projectSourcesShard(for: rootDirectory)))
        }
        let methods = activeLines / 5
        let activeText = """
        package app0;

        import java.util.*;

        public class Active {
        \(JavaCompletionProfile.filler(methods))
            void test(List<String> names) {
                names
            }
        }

        """
        let activeFile = directory.appendingPathComponent("m0/src/main/java/app0/Active.java")
        try activeText.write(to: activeFile, atomically: false, encoding: .utf8)
        let dot = (activeText as NSString).range(of: "names\n").upperBound - 1

        let jdkShard = jdkPaths.jdkShard(jdk, kind: "ctsym")
        var targets: [(root: any JavaIndexableRoot, shardURL: URL)] = roots.map { (SourceRoot(directory: $0.directory), $0.shardURL) }
        targets.append((JDKCtSymRoot(installation: jdk), jdkShard))
        for await _ in await JavaIndexScheduler(paths: jdkPaths).index(targets) {}
        var sources: [JavaIndex.Source] = []
        for root in roots { sources.append(.init(precedence: 1, reader: try JavaIndexShardReader(url: root.shardURL), shardPath: root.shardURL.path)) }
        sources += try JavaCompletionProfile.writeJarShards(count: jars, in: directory)
        sources.append(.init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard)))
        let index = JavaIndex()
        await index.setSources(sources)
        let names = sources.reduce(0) { $0 + $1.reader.allQualifiedNames.count }
        return SaveSetup(
            summary: "synthetic: \(modules) module(s) of \(filesPerModule) files, \(jars) jars, \(names) names, active file \(activeText.split(separator: "\n", omittingEmptySubsequences: false).count) lines",
            index: index, provider: JavaCompletionProvider(index: index), scheduler: scheduler, sources: sources,
            rootDirectory: roots[0].directory, shardURL: roots[0].shardURL, shardPath: roots[0].shardURL.path,
            activeFile: activeFile, activeText: activeText, dotOffset: dot, rootFileCount: filesPerModule + 1
        )
    }

    static func project(named name: String, variants: [String]) throws -> SaveSetup {
        let environment = try ProjectEnvironment.load(named: name)
        guard let index = environment.index, let scheduler = environment.scheduler else { throw LatencyFailure(message: "project has no index") }
        // The biggest typical file of the project: the one most worth a save.
        for file in environment.pickFiles(count: 3).reversed() {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let site = ProjectEnvironmentSites.firstDot(in: text),
                  let root = environment.sourceRoots.filter({ file.path.hasPrefix($0.directory.path + "/") }).max(by: { $0.directory.path.count < $1.directory.path.count })
            else { continue }
            let removed = ProjectEnvironmentSites.removingDot(at: site, from: text)
            let count = ProjectEnvironment.javaFiles(under: root.directory).count
            var setup = SaveSetup(
                summary: "\(name): \(environment.summary); file \(file.lastPathComponent) (read only: the project's files are not written)",
                index: index, provider: environment.provider, scheduler: scheduler, sources: environment.sources,
                rootDirectory: root.directory, shardURL: root.shardURL, shardPath: root.shardPath,
                activeFile: file, activeText: removed, dotOffset: site, rootFileCount: count
            )
            setup.writesFile = false
            return setup
        }
        throw LatencyFailure(message: "no file with a member access in a source root of \(name)")
    }

    // MARK: Measuring

    private func context(for text: String, version: Int) -> CompletionContext {
        let ns = text as NSString
        let typed = ns.replacingCharacters(in: NSRange(location: dotOffset, length: 0), with: ".")
        let before = ns.substring(to: dotOffset) as NSString
        let line = before.components(separatedBy: "\n").count - 1
        let lineStart = before.range(of: "\n", options: .backwards)
        let column = dotOffset - (lineStart.location == NSNotFound ? 0 : lineStart.upperBound) + 1
        let position = TextPosition(line: line, column: column, utf16Offset: dotOffset + 1)
        let document = Document(
            id: DocumentID(), url: activeFile, displayName: activeFile.lastPathComponent,
            contentSnapshot: TextSnapshot(version: version, text: typed),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        return makeCompletionContext(document: document, trigger: .keystroke("."))
    }

    /// Milliseconds until the provider's first and last updates for a request at the dot.
    private func complete(_ text: String, version: Int) async -> (first: Double, last: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        var first: Double?
        var last = 0.0
        for await update in provider.provideUpdates(context: context(for: text, version: version)) {
            if update.isFinished, update.items.isEmpty { print("    (the request returned no items)") }
            if ProcessInfo.processInfo.environment["SAVE_DEBUG"] != nil { print("    update: \(update.items.count) items finished=\(update.isFinished)") }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6
            if first == nil { first = elapsed }
            last = elapsed
        }
        return (first ?? last, last)
    }

    private func milliseconds(_ body: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6
    }

    func measure(saves: Int, variant: Variant) async -> Report {
        var report = Report()
        var sources = self.sources
        // Warm the provider the way a session would be before the save.
        for round in 0..<3 { _ = await complete(activeText, version: round) }
        let sourceIndex = sources.firstIndex { $0.shardPath == shardPath } ?? 0
        let broken = "\n    // save broken\n    int broken = ;\n"
        for save in 0..<saves {
            let baseline = await complete(activeText, version: 10 + save)
            report.baseline.append(baseline.last)

            // The edit and the write: what ⌘S puts on disk.
            let saved: String
            switch variant {
            case .unchanged: saved = activeText
            case .edited: saved = activeText + "\n// save \(save)\n"
            case .syntaxError: saved = activeText + broken + "// save \(save)\n"
            }
            if writesFile { try? saved.write(to: activeFile, atomically: false, encoding: .utf8) }

            // `refreshStubs`: the whole root is parsed again, then the reader is opened.
            report.indexing.append(await milliseconds { for await _ in await scheduler.index([(SourceRoot(directory: rootDirectory), shardURL)], force: true) {} })
            var reader: JavaIndexShardReader?
            report.reader.append(await milliseconds { reader = try? JavaIndexShardReader(url: shardURL) })
            guard let reader else { continue }
            let old = sources[sourceIndex]
            sources[sourceIndex] = JavaIndex.Source(precedence: old.precedence, reader: reader, shardPath: old.shardPath)

            // `publishSources`, with a completion asked while it runs: it queues behind the rebuild on the index actor.
            let published = sources
            let index = self.index
            let publish = Task { await milliseconds { await index.setSources(published) } }
            await Task.yield()
            let during = await complete(saved, version: 100 + save)
            report.during.append(during.last)
            report.setSources.append(await publish.value)

            let after = await complete(saved, version: 200 + save)
            report.after.append(after.last)
            report.afterSecond.append((await complete(saved, version: 300 + save)).last)
        }
        return report
    }
}

/// Site finding that does not need the profile's private helpers.
private enum ProjectEnvironmentSites {
    static func firstDot(in text: String) -> Int? {
        let ns = text as NSString
        var found: Int?
        var index = 0
        let units = Array(text.utf16)
        var inLine = false
        while index + 1 < units.count, found == nil {
            if units[index] == 0x0A { inLine = false }
            if units[index] == 0x2E, index > 0, index + 1 < units.count {
                let before = units[index - 1], after = units[index + 1]
                let beforeOK = (before >= 0x61 && before <= 0x7A) || (before >= 0x41 && before <= 0x5A) || before == 0x29
                let afterOK = (after >= 0x61 && after <= 0x7A) || (after >= 0x41 && after <= 0x5A)
                let lineStart = ns.lineRange(for: NSRange(location: index, length: 0))
                let line = ns.substring(with: lineStart).trimmingCharacters(in: .whitespaces)
                if beforeOK, afterOK, !line.hasPrefix("import "), !line.hasPrefix("package "), !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("/*"), !inLine {
                    found = index
                }
            }
            index += 1
        }
        return found
    }

    static func removingDot(at offset: Int, from text: String) -> String {
        var units = Array(text.utf16)
        units.remove(at: offset)
        return String(decoding: units, as: UTF16.self)
    }
}
