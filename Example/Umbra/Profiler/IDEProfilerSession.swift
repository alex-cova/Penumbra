import Foundation
import JavaIntelligence
import Observation

/// One open recording: reading it, and what the profiler tab is looking at.
///
/// The recording is read by the JDK's own `jfr print` as a stream into a prefix tree
/// (`JavaProfileTree`), off the main actor; a result that a newer import overtook is dropped. The
/// view only reads the tree.
@MainActor
@Observable
final class IDEProfilerSession {
    enum Phase: Equatable {
        case idle
        case summarizing
        case reading(lines: Int)
        case ready
        case failed(String)
        /// No installed JDK has a `jfr` tool.
        case needsJDK
        /// The file is bigger than the threshold: asks before reading.
        case needsConfirmation(megabytes: Int)
        /// The run is still going: charts of the JVM, until it ends and its recording is read.
        case live
    }

    enum Kind: String, CaseIterable, Identifiable {
        case cpu = "CPU"
        case allocations = "Allocations"
        case locks = "Waits"
        case gc = "GC"

        var id: String { rawValue }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case flame = "Flame Graph"
        case hot = "Hot Methods"
        case tree = "Call Tree"
        case timeline = "Timeline"

        var id: String { rawValue }
    }

    /// A "what if" applied to the shown tree, in order. Each one names nodes of the tree it was made
    /// on, which is the result of the ones before it, so they only make sense as a chain.
    enum Transform: Equatable, Identifiable {
        case focusSubtree(node: Int, label: String)
        case focusCall(method: Int32, label: String)
        case excludeSubtree(node: Int, label: String)
        case excludeCalls(method: Int32, label: String)

        var id: String {
            switch self {
            case .focusSubtree(let node, _): return "focus-subtree-\(node)"
            case .focusCall(let method, _): return "focus-call-\(method)"
            case .excludeSubtree(let node, _): return "exclude-subtree-\(node)"
            case .excludeCalls(let method, _): return "exclude-calls-\(method)"
            }
        }

        var title: String {
            switch self {
            case .focusSubtree(_, let label): return "Subtree: \(label)"
            case .focusCall(_, let label): return "Call: \(label)"
            case .excludeSubtree(_, let label): return "Without subtree: \(label)"
            case .excludeCalls(_, let label): return "Without: \(label)"
            }
        }
    }

    /// A class the tree leaves out: its frame is removed and what it called attaches to its caller,
    /// which is how a profiler hides the JDK, a library, or a framework's plumbing.
    enum ClassFilter: Hashable, Identifiable {
        case jdk
        case libraries
        case pattern(JavaClassPattern)

        var id: String {
            switch self {
            case .jdk: return "jdk"
            case .libraries: return "libraries"
            case .pattern(let pattern): return "pattern-\(pattern.text)"
            }
        }

        var title: String {
            switch self {
            case .jdk: return "Hiding JDK classes"
            case .libraries: return "Hiding libraries"
            case .pattern(let pattern): return "Hiding \(pattern.text)"
            }
        }
    }

    /// What a percentage in the tables is a share of.
    enum PercentBase: String, CaseIterable, Identifiable {
        case total = "Percent of Total"
        case parent = "Percent of Parent"

        var id: String { rawValue }
    }

    /// Where a frame's code comes from, for colour: the project's sources, a library, the JDK, or
    /// no class at all (a marker the importer added, such as `new byte[]` or `sleeping`).
    enum FrameOrigin: Equatable {
        case project
        case library
        case jdk
        case marker
    }

    let id = UUID()
    /// The run's recordings: known when the run ends for a live session.
    private(set) var recordings: [URL]
    /// The tab title: the file's name, or "Profile: <configuration>" for a run's own recording.
    let title: String
    /// Set when the recording is a run's own (in the cache), so it is not kept open as the user's file.
    let runID: String?

    private(set) var phase: Phase = .idle
    private(set) var profile: JavaProfile?
    private(set) var summary: JFRSummary?
    private(set) var loadedAt: Date?

    var kind: Kind = .cpu {
        didSet { if kind != oldValue { resetNavigation() } }
    }
    /// Bumped whenever what the tab shows could be a different tree of the same size (another kind,
    /// thread or recording), so a view that caches a layout by node count knows to rebuild it.
    private(set) var treeRevision = 0
    var mode: Mode = .flame
    /// A thread name to look at; `nil` is every thread (CPU only).
    var thread: String? {
        didSet { if thread != oldValue { resetNavigation() } }
    }
    var searchText = "" {
        didSet { if searchText != oldValue { searchCursor = 0 } }
    }
    /// Which match of the search the flame graph is on, counted from 0 and wrapping.
    var searchCursor = 0
    /// The "what if"s applied to the tree, oldest first.
    var transforms: [Transform] = [] {
        didSet { if transforms != oldValue { resetNavigation() } }
    }
    /// Recursive calls merged back into the first call. Changing it clears the "what if"s: their
    /// nodes were made on the other shape of the tree.
    var collapsesRecursion = false {
        didSet {
            guard collapsesRecursion != oldValue else { return }
            transforms = []
            resetNavigation()
        }
    }
    /// Classes left out of every view, in the order they were asked for. Like collapsing recursion,
    /// changing them clears the "what if"s, whose nodes were made on the other shape of the tree.
    var classFilters: [ClassFilter] = [] {
        didSet {
            guard classFilters != oldValue else { return }
            transforms = []
            resetNavigation()
        }
    }
    var percentBase: PercentBase = .total
    /// The part of the recording the views are limited to, in milliseconds from its origin; set by
    /// dragging across the timeline. Applies to the samples' start times.
    var timeRange: ClosedRange<Int32>? {
        didSet { if timeRange != oldValue { resetNavigation() } }
    }
    /// The sample a click on the timeline landed on, whose stack the side panel shows.
    var timelineEvent: TimelineEvent?

    struct TimelineEvent: Equatable {
        var thread: String
        var kind: JavaSampleKind
        var time: Int32
        var node: Int
    }
    /// Nodes with a smaller share of the whole than this (percent) are drawn faded; 0 is off.
    var nodeThresholdPercent: Double = 0
    /// The method selected in the table or the graph.
    var selectedMethod: Int32?
    /// Tree nodes the flame graph was zoomed into, outermost first.
    var zoomStack: [Int] = []

    /// How much of one sample's time to say a sample stands for, in milliseconds: read off the
    /// recording's own sample gaps, 10 (the `profile` setting's) when there are too few.
    private(set) var samplePeriodMilliseconds: Double = 10

    // Injected by the workspace.
    /// JDKs to read the recording with, best first: the project's, then the newest installed. A
    /// newer `jfr` reads older recordings, so a failure moves on to the next.
    @ObservationIgnored var jfrCandidates: (() async -> [JDKInstallation])?
    @ObservationIgnored var confirmThresholdBytes = 500 * 1024 * 1024
    @ObservationIgnored var openFrame: ((_ className: String, _ line: Int) -> Void)?
    @ObservationIgnored var chooseJDK: (() -> Void)?
    @ObservationIgnored var openAsHex: (() -> Void)?
    /// Whether a class (a binary name) is the project's own or a library's; the workspace knows the
    /// source roots. Unset, every non-JDK class counts as a library.
    @ObservationIgnored var classifyClass: ((String) -> FrameOrigin)?
    @ObservationIgnored weak var flameGraphView: IDEFlameGraphNSView?
    @ObservationIgnored private var originCache: [Int32: FrameOrigin] = [:]

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(recordings: [URL], title: String, runID: String? = nil) {
        self.recordings = recordings
        self.title = title
        self.runID = runID
    }

    deinit {
        task?.cancel()
    }

    var primaryRecording: URL? { recordings.first }

    // MARK: - Loading

    func load(confirmed: Bool = false) {
        // A run in progress has nothing to read yet; `finishLive` calls this once it has.
        if phase == .live { return }
        task?.cancel()
        generation += 1
        let current = generation
        phase = .summarizing
        let recordings = recordings
        let provider = jfrCandidates
        let threshold = confirmThresholdBytes
        let progress: @Sendable (Int) -> Void = { [weak self] lines in
            Task { @MainActor in self?.setProgress(lines: lines, generation: current) }
        }
        task = Task { [weak self] in
            let candidates = (await provider?() ?? []).filter { $0.jfr != nil }
            guard !candidates.isEmpty else {
                self?.finish(generation: current, phase: .needsJDK)
                return
            }
            let bytes = recordings.reduce(0) { total, url in
                total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
            }
            if !confirmed, bytes > threshold {
                self?.finish(generation: current, phase: .needsConfirmation(megabytes: bytes / (1024 * 1024)))
                return
            }
            var lastFailure = "The recording could not be read."
            for jdk in candidates.prefix(3) {
                guard !Task.isCancelled, let jfr = jdk.jfr else { return }
                // The header read is quick and tells how big the import is before the stacks stream.
                if let first = recordings.first,
                   let summary = try? await JavaRecordingImporter.summary(jfr: jfr, recording: first) {
                    await self?.setSummary(summary, generation: current)
                }
                guard !Task.isCancelled else { return }
                await self?.setPhase(.reading(lines: 0), generation: current)
                do {
                    let profile = try await JavaRecordingImporter.importProfile(
                        jfr: jfr, recordings: recordings, progress: progress
                    )
                    await self?.setProfile(profile, generation: current)
                    return
                } catch JavaRecordingImportError.cancelled {
                    return
                } catch {
                    lastFailure = error.localizedDescription
                }
            }
            await self?.setPhase(.failed(lastFailure), generation: current)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        live?.stop()
    }

    // MARK: - Live

    /// The monitor of a run in progress; kept after the run for the charts' last readings.
    private(set) var live: IDEProfilerLiveMonitor?
    /// Stops the run this session shows (set by the workspace).
    @ObservationIgnored var stopRun: (() -> Void)?
    /// Opens a snapshot of the running JVM as a profile tab of its own.
    @ObservationIgnored var openSnapshot: ((URL) -> Void)?

    /// Shows charts of a run's JVM until its recording exists.
    func beginLive(monitor: IDEProfilerLiveMonitor) {
        live = monitor
        phase = .live
        monitor.start()
    }

    /// The run ended: reads its recordings into the report, in this same tab.
    func finishLive(recordings: [URL]) {
        self.recordings = recordings
        live?.stop()
        guard phase == .live || phase == .idle else { return }
        phase = .idle
        load(confirmed: false)
    }

    /// The run ended without a recording: the tab says so.
    func failLive(_ message: String) {
        live?.stop()
        guard phase == .live else { return }
        phase = .failed(message)
    }

    private func finish(generation: Int, phase: Phase) {
        guard generation == self.generation else { return }
        self.phase = phase
        switch phase {
        case .failed, .needsJDK, .needsConfirmation: onLoaded?()
        default: break
        }
    }

    private func setPhase(_ phase: Phase, generation: Int) {
        finish(generation: generation, phase: phase)
    }

    private func setSummary(_ summary: JFRSummary, generation: Int) {
        guard generation == self.generation else { return }
        self.summary = summary
    }

    private func setProgress(lines: Int, generation: Int) {
        guard generation == self.generation, case .reading = phase else { return }
        phase = .reading(lines: lines)
    }

    private func setProfile(_ profile: JavaProfile, generation: Int) {
        guard generation == self.generation else { return }
        self.profile = profile
        loadedAt = Date()
        samplePeriodMilliseconds = profile.estimatedCPUSamplePeriodMilliseconds() ?? 10
        phase = .ready
        resetNavigation()
        if profile.cpuSamples == 0, profile.allocation.totalSamples > 0 { kind = .allocations }
        onLoaded?()
        onQueryChanged?()
    }

    // MARK: - Tests

    /// Puts a finished profile in the session without a recording behind it (view tests).
    func setProfileForTesting(_ profile: JavaProfile) {
        self.profile = profile
        loadedAt = Date()
        samplePeriodMilliseconds = profile.estimatedCPUSamplePeriodMilliseconds() ?? 10
        phase = .ready
        treeRevision += 1
    }

    func setPhaseForTesting(_ phase: Phase) {
        self.phase = phase
    }

    // MARK: - What the tab shows

    /// The tree of the selected kind and thread, with recursion collapsed and the "what if"s applied.
    /// Kept for as long as none of those change, since every view reads it on every update.
    var tree: JavaProfileTree? {
        guard let profile, let sampleKind else { return nil }
        let key = DisplayKey(
            kind: kind, thread: thread, collapse: collapsesRecursion, transforms: transforms, generation: generation,
            range: timeRange, classFilters: classFilters
        )
        if let cached = displayCache, cached.key == key { return cached.tree }
        let symbols = profile.symbols
        var result = hidingClassFilters(in: profile.tree(of: sampleKind, thread: thread, range: timeRange), symbols: symbols)
        if collapsesRecursion { result = result.collapsingRecursion(symbols: symbols) }
        for transform in transforms {
            switch transform {
            case .focusSubtree(let node, _): result = result.focusingOnSubtree(of: node)
            case .focusCall(let method, _): result = result.focusingOnCall(of: method, symbols: symbols)
            case .excludeSubtree(let node, _): result = result.excludingSubtree(of: node)
            case .excludeCalls(let method, _): result = result.excludingCalls(of: method, symbols: symbols)
            }
        }
        displayCache = (key, result)
        return result
    }

    private struct DisplayKey: Equatable {
        var kind: Kind
        var thread: String?
        var collapse: Bool
        var transforms: [Transform]
        var generation: Int
        var range: ClosedRange<Int32>?
        var classFilters: [ClassFilter]
    }

    /// `tree` without the frames of the hidden classes (both profiles of a comparison go through
    /// this, so a hidden library is hidden on each side).
    private func hidingClassFilters(in tree: JavaProfileTree, symbols: JavaProfileSymbols) -> JavaProfileTree {
        guard !classFilters.isEmpty else { return tree }
        let filters = classFilters
        return tree.hidingFrames(symbols: symbols) { method in
            !method.className.isEmpty && filters.contains { self.hides($0, className: method.className) }
        }
    }

    private func hides(_ filter: ClassFilter, className: String) -> Bool {
        switch filter {
        case .jdk: return Self.isJDKClass(className)
        case .libraries:
            // Without a project to tell from a library, hiding "libraries" would hide everything.
            guard let classifyClass, !Self.isJDKClass(className) else { return false }
            return classifyClass(className) == .library
        case .pattern(let pattern): return pattern.matches(className: className)
        }
    }

    func addClassFilter(_ filter: ClassFilter) {
        if !classFilters.contains(filter) { classFilters.append(filter) }
    }

    func removeClassFilter(_ filter: ClassFilter) {
        classFilters.removeAll { $0 == filter }
    }

    func toggleClassFilter(_ filter: ClassFilter) {
        if classFilters.contains(filter) { removeClassFilter(filter) } else { addClassFilter(filter) }
    }

    /// The package of a class name, for "Hide Package".
    static func packageName(of className: String) -> String? {
        guard let dot = className.lastIndex(of: ".") else { return nil }
        return String(className[..<dot])
    }

    @ObservationIgnored private var displayCache: (key: DisplayKey, tree: JavaProfileTree)?

    /// The kind of sample behind the selected event kind; `nil` for GC, which is a list.
    var sampleKind: JavaSampleKind? {
        switch kind {
        case .cpu: return .cpu
        case .allocations: return .allocation
        case .locks: return .contention
        case .gc: return nil
        }
    }

    var symbols: JavaProfileSymbols? { profile?.symbols }

    /// Hot methods of the shown tree, cached by what they were computed from.
    var hotMethods: [JavaProfileTree.HotMethod] {
        guard let tree, let symbols else { return [] }
        let key = HotKey(kind: kind, thread: thread, generation: generation, revision: treeRevision)
        if let cached = hotCache, cached.key == key { return cached.rows }
        let rows = tree.hotMethods(symbols: symbols)
        hotCache = (key, rows)
        return rows
    }

    private struct HotKey: Equatable {
        var kind: Kind
        var thread: String?
        var generation: Int
        var revision: Int
    }

    @ObservationIgnored private var hotCache: (key: HotKey, rows: [JavaProfileTree.HotMethod])?

    /// Thread names of the selected kind by sample count, most samples first.
    var threadNames: [String] {
        guard let profile, let sampleKind else { return [] }
        return profile.threads(of: sampleKind).map(\.name)
    }

    /// `12 340 samples · ~123 s` for the shown tree.
    var totalDescription: String {
        guard let tree else { return "" }
        let total = tree.totalSamples
        switch kind {
        case .cpu:
            let seconds = Double(total) * samplePeriodMilliseconds / 1000
            return "\(total.formatted()) samples · ~\(String(format: "%.1f", seconds)) s of CPU"
        case .allocations:
            return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory) + " sampled"
        case .locks:
            return "\(String(format: "%.1f", Double(total) / 1000)) ms waiting"
        case .gc:
            return ""
        }
    }

    func percent(_ count: Int) -> Double {
        percent(count, of: nil)
    }

    /// `count` as a share of `base` samples, or of the whole shown tree when `base` is `nil`
    /// (or when the share of the parent was not asked for).
    func percent(_ count: Int, of base: Int?) -> Double {
        let total = base ?? tree?.totalSamples ?? 0
        guard total > 0 else { return 0 }
        return Double(count) * 100 / Double(total)
    }

    enum DetailKind: Equatable {
        case backTrace
        case mergedCallees
    }

    /// The tree behind the method list's Back Traces and Merged Callees for `method`, made once
    /// per method and shown tree.
    func detailTree(_ kind: DetailKind, method: Int32) -> JavaProfileTree? {
        guard let tree, let symbols else { return nil }
        let key = DetailKey(kind: kind, method: method, revision: treeRevision, generation: generation)
        if let cached = detailCache, cached.key == key { return cached.tree }
        let result: JavaProfileTree
        switch kind {
        case .backTrace: result = tree.backTrace(of: method, symbols: symbols)
        case .mergedCallees: result = tree.mergedCallees(of: method, symbols: symbols)
        }
        detailCache = (key, result)
        return result
    }

    private struct DetailKey: Equatable {
        var kind: DetailKind
        var method: Int32
        var revision: Int
        var generation: Int
    }

    @ObservationIgnored private var detailCache: (key: DetailKey, tree: JavaProfileTree)?

    func resetNavigation() {
        zoomStack = []
        selectedMethod = nil
        treeRevision += 1
        onQueryChanged?()
    }

    /// Told when what the tab shows changed (kind, thread, range, a "what if", a new recording), so
    /// the editor's line hints follow it.
    @ObservationIgnored var onQueryChanged: (() -> Void)?

    // MARK: - Baseline

    /// A recording to compare against: an open tab (already read, so `profile` is set), a run's
    /// folder, or a file.
    struct BaselineCandidate: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var recordings: [URL]
        var profile: JavaProfile?
    }

    enum BaselineState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// Set by the workspace: what can be chosen as a baseline, how to read one from files (a session
    /// with the same JDK candidates as this one), and the file chooser.
    @ObservationIgnored var baselineCandidates: (() -> [BaselineCandidate])?
    @ObservationIgnored var makeBaselineSession: (([URL], String) -> IDEProfilerSession)?
    @ObservationIgnored var chooseBaselineFile: (() -> Void)?
    /// Called when this session's recording has been read; the baseline's session uses it.
    @ObservationIgnored var onLoaded: (() -> Void)?

    private(set) var baselineTitle: String?
    private(set) var baselineState: BaselineState?
    private(set) var baselineProfile: JavaProfile?
    @ObservationIgnored private var baselineSession: IDEProfilerSession?
    /// Whether the merged tree is by share of each profile (the default) or by raw sample counts.
    var comparisonBasis: JavaProfileComparison.Basis = .share

    var isComparing: Bool { baselineProfile != nil }

    func setBaseline(_ candidate: BaselineCandidate) {
        clearBaseline()
        baselineTitle = candidate.title
        if let profile = candidate.profile {
            baselineProfile = profile
            baselineState = .ready
            resetNavigation()
            return
        }
        guard let make = makeBaselineSession else { return }
        baselineState = .loading
        let loader = make(candidate.recordings, candidate.title)
        baselineSession = loader
        loader.onLoaded = { [weak self, weak loader] in
            guard let self, let loader, self.baselineSession === loader else { return }
            self.baselineSession = nil
            if let profile = loader.profile {
                self.baselineProfile = profile
                self.baselineState = .ready
                self.resetNavigation()
                return
            }
            switch loader.phase {
            case .failed(let message): self.baselineState = .failed(message)
            case .needsJDK: self.baselineState = .failed("No installed JDK has a `jfr` tool to read the baseline.")
            default: self.baselineState = .failed("The baseline could not be read.")
            }
        }
        loader.load(confirmed: true)
    }

    func clearBaseline() {
        baselineSession?.cancel()
        baselineSession = nil
        let hadBaseline = baselineProfile != nil
        baselineProfile = nil
        baselineTitle = nil
        baselineState = nil
        if hadBaseline { resetNavigation() }
    }

    /// The shown tree against the baseline's tree of the same kind and thread (whole recording:
    /// a time range and the "what if"s belong to this profile's axis and calls). `nil` without one.
    var comparison: JavaProfileComparison? {
        guard let baselineProfile, let profile, let sampleKind, let target = tree else { return nil }
        guard !(comparisonCompatibility?.isIncompatible ?? false) else { return nil }
        let key = ComparisonKey(
            display: DisplayKey(
                kind: kind, thread: thread, collapse: collapsesRecursion, transforms: transforms,
                generation: generation, range: timeRange, classFilters: classFilters
            ),
            basis: comparisonBasis, baselineSamples: baselineProfile.cpuSamples + baselineProfile.allocation.totalSamples
                + baselineProfile.contention.totalSamples,
            baselineTitle: baselineTitle
        )
        if let cached = comparisonCache, cached.key == key { return cached.comparison }
        let base = hidingClassFilters(
            in: baselineProfile.tree(of: sampleKind, thread: thread, range: nil), symbols: baselineProfile.symbols
        )
        let result = JavaProfileComparison.compare(
            baseline: base, baselineSymbols: baselineProfile.symbols,
            target: target, targetSymbols: profile.symbols, basis: comparisonBasis
        )
        comparisonCache = (key, result)
        return result
    }

    /// Whether the baseline can be set against this recording for the shown kind and thread: a
    /// sentence when it cannot (nothing is drawn as a difference then) or when a number needs a caveat.
    /// `nil` without a baseline.
    var comparisonCompatibility: JavaProfileComparison.Compatibility? {
        guard let baselineProfile, let profile, let sampleKind else { return nil }
        return JavaProfileComparison.compatibility(
            baseline: baselineProfile, target: profile, kind: sampleKind, thread: thread, basis: comparisonBasis
        )
    }

    private struct ComparisonKey: Equatable {
        var display: DisplayKey
        var basis: JavaProfileComparison.Basis
        var baselineSamples: Int
        var baselineTitle: String?
    }

    @ObservationIgnored private var comparisonCache: (key: ComparisonKey, comparison: JavaProfileComparison)?

    // MARK: - Timeline

    /// The recording over time, made on first use and kept; `nil` for a profile with no times.
    var timeline: JavaProfileTimeline? {
        guard let profile else { return nil }
        if let cached = timelineCache, cached.generation == generation { return cached.timeline }
        let built = JavaProfileTimeline.build(from: profile)
        timelineCache = (generation, built)
        return built
    }

    @ObservationIgnored private var timelineCache: (generation: Int, timeline: JavaProfileTimeline?)?

    /// Selects the sample of `thread` nearest `time` (or clears the selection when there is none).
    func selectTimelineEvent(thread: String, near time: Int32, toleranceMilliseconds: Int32) {
        guard let profile,
              let hit = profile.nearestSample(thread: thread, time: time, tolerance: toleranceMilliseconds) else {
            timelineEvent = nil
            return
        }
        timelineEvent = TimelineEvent(thread: thread, kind: hit.kind, time: hit.time, node: hit.node)
    }

    /// The frames of the selected timeline event, leaf first.
    var timelineEventFrames: [Int32] {
        guard let profile, let event = timelineEvent else { return [] }
        let tree = profile.tree(of: event.kind)
        guard event.node >= 0, event.node < tree.nodeCount else { return [] }
        return tree.path(to: event.node).reversed()
    }

    /// `0.42 s` from the recording's start.
    func formattedOffset(_ time: Int32) -> String {
        let origin = profile?.timeSpan?.lowerBound ?? 0
        return String(format: "%.2f s", Double(time - origin) / 1000)
    }

    // MARK: - What if

    /// Short name for a chip: `Class.method` of the frame at `node` (or of `method`).
    func label(ofNode node: Int) -> String {
        guard let tree, let symbols, node >= 0, node < tree.nodeCount else { return "frame" }
        return IDEFlameGraphNSView.label(frame: tree.frame(of: node), symbols: symbols)
    }

    func label(ofMethod method: Int32) -> String {
        guard let symbols, Int(method) < symbols.methods.count else { return "method" }
        return symbols.displayName(ofMethod: method)
    }

    func methodOf(node: Int) -> Int32? {
        guard let tree, let symbols, node > 0, node < tree.nodeCount else { return nil }
        let frame = tree.frame(of: node)
        return frame >= 0 ? symbols.frame(frame).method : nil
    }

    func focusOnSubtree(node: Int) {
        guard node > 0 else { return }
        transforms.append(.focusSubtree(node: node, label: label(ofNode: node)))
    }

    func focusOnCall(node: Int) {
        guard let method = methodOf(node: node) else { return }
        transforms.append(.focusCall(method: method, label: label(ofMethod: method)))
    }

    func excludeSubtree(node: Int) {
        guard node > 0 else { return }
        transforms.append(.excludeSubtree(node: node, label: label(ofNode: node)))
    }

    func excludeCalls(node: Int) {
        guard let method = methodOf(node: node) else { return }
        transforms.append(.excludeCalls(method: method, label: label(ofMethod: method)))
    }

    func removeTransform(_ transform: Transform) {
        transforms.removeAll { $0 == transform }
    }

    // MARK: - Colour

    func origin(ofMethod method: Int32) -> FrameOrigin {
        if let known = originCache[method] { return known }
        guard let symbols, Int(method) < symbols.methods.count else { return .library }
        let origin = origin(ofClass: symbols.methods[Int(method)].className)
        originCache[method] = origin
        return origin
    }

    /// Where a class comes from; the empty name of a marker frame is its own origin.
    func origin(ofClass className: String) -> FrameOrigin {
        if className.isEmpty { return .marker }
        if Self.isJDKClass(className) { return .jdk }
        return classifyClass?(className) ?? .library
    }

    static func isJDKClass(_ className: String) -> Bool {
        className.hasPrefix("java.") || className.hasPrefix("javax.") || className.hasPrefix("jdk.")
            || className.hasPrefix("sun.") || className.hasPrefix("com.sun.")
    }

    // MARK: - Search

    /// The nodes of the shown tree (below the zoomed frame) whose method name contains the search
    /// text, in drawing order: left to right, top to bottom within a branch.
    var searchMatches: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, let tree, let symbols else { return [] }
        let root = min(zoomStack.last ?? JavaProfileTree.root, max(tree.nodeCount - 1, 0))
        let key = SearchKey(query: query, revision: treeRevision, root: root)
        if let cached = searchCache, cached.key == key { return cached.nodes }
        var methodMatches: [Int32: Bool] = [:]
        var result: [Int] = []
        var stack = [root]
        while let node = stack.popLast(), result.count < 5_000 {
            let frame = tree.frame(of: node)
            if frame >= 0 {
                let method = symbols.frame(frame).method
                let matches: Bool
                if let known = methodMatches[method] {
                    matches = known
                } else {
                    matches = symbols.qualifiedName(ofMethod: method).lowercased().contains(query)
                    methodMatches[method] = matches
                }
                if matches { result.append(node) }
            }
            // Pushed in reverse so the hottest child is read first.
            for child in tree.children(of: node).reversed() { stack.append(child) }
        }
        searchCache = (key, result)
        return result
    }

    private struct SearchKey: Equatable {
        var query: String
        var revision: Int
        var root: Int
    }

    @ObservationIgnored private var searchCache: (key: SearchKey, nodes: [Int])?

    /// The match the cursor is on, if there are any.
    var focusedMatch: Int? {
        let matches = searchMatches
        guard !matches.isEmpty else { return nil }
        return matches[((searchCursor % matches.count) + matches.count) % matches.count]
    }

    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        searchCursor = (searchCursor + 1) % searchMatches.count
    }

    func previousMatch() {
        let count = searchMatches.count
        guard count > 0 else { return }
        searchCursor = (searchCursor - 1 + count) % count
    }

    /// The collections the GC table lists: all, or those that started inside the time range.
    var visibleGCPauses: [JavaGCPause] {
        guard let profile else { return [] }
        guard let range = timeRange else { return profile.gcPauses }
        return profile.gcPauses.filter { $0.startMilliseconds.map(range.contains) ?? false }
    }

    func resetZoom() {
        zoomStack = []
    }

    func zoom(into node: Int) {
        guard zoomStack.last != node else { return }
        zoomStack.append(node)
    }

    func zoomOut() {
        _ = zoomStack.popLast()
    }

    // MARK: - Source

    /// `className` and line of a frame, for opening its source.
    func frameLocation(_ frame: Int32) -> (className: String, line: Int)? {
        guard let symbols else { return nil }
        let method = symbols.method(ofFrame: frame)
        guard !method.className.isEmpty else { return nil }
        return (method.className, Int(symbols.frame(frame).line))
    }

    func openSource(ofMethod method: Int32, line: Int = 0) {
        guard let symbols else { return }
        let className = symbols.methods[Int(method)].className
        guard !className.isEmpty else { return }
        openFrame?(className, line)
    }

    /// Folded stacks of the shown tree, for other flame-graph tools.
    func foldedStacks() -> String? {
        guard let tree, let symbols else { return nil }
        return tree.foldedStacks(symbols: symbols).joined(separator: "\n") + "\n"
    }
}
