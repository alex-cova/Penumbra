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
    }

    enum Kind: String, CaseIterable, Identifiable {
        case cpu = "CPU"
        case allocations = "Allocations"
        case locks = "Locks"
        case gc = "GC"

        var id: String { rawValue }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case flame = "Flame Graph"
        case hot = "Hot Methods"
        case tree = "Call Tree"

        var id: String { rawValue }
    }

    let id = UUID()
    let recordings: [URL]
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
    var mode: Mode = .flame
    /// A thread name to look at; `nil` is every thread (CPU only).
    var thread: String? {
        didSet { if thread != oldValue { resetNavigation() } }
    }
    var searchText = ""
    /// The method selected in the table or the graph.
    var selectedMethod: Int32?
    /// Tree nodes the flame graph was zoomed into, outermost first.
    var zoomStack: [Int] = []

    /// How much of one sample's time to say a sample stands for, in milliseconds.
    var samplePeriodMilliseconds: Double { 10 }

    // Injected by the workspace.
    /// JDKs to read the recording with, best first: the project's, then the newest installed. A
    /// newer `jfr` reads older recordings, so a failure moves on to the next.
    @ObservationIgnored var jfrCandidates: (() async -> [JDKInstallation])?
    @ObservationIgnored var confirmThresholdBytes = 500 * 1024 * 1024
    @ObservationIgnored var openFrame: ((_ className: String, _ line: Int) -> Void)?
    @ObservationIgnored var chooseJDK: (() -> Void)?
    @ObservationIgnored var openAsHex: (() -> Void)?

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
    }

    private func finish(generation: Int, phase: Phase) {
        guard generation == self.generation else { return }
        self.phase = phase
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
        phase = .ready
        resetNavigation()
        if profile.cpuSamples == 0, profile.allocation.totalSamples > 0 { kind = .allocations }
    }

    // MARK: - Tests

    /// Puts a finished profile in the session without a recording behind it (view tests).
    func setProfileForTesting(_ profile: JavaProfile) {
        self.profile = profile
        loadedAt = Date()
        phase = .ready
    }

    func setPhaseForTesting(_ phase: Phase) {
        self.phase = phase
    }

    // MARK: - What the tab shows

    /// The tree of the selected kind (and thread, for CPU).
    var tree: JavaProfileTree? {
        guard let profile else { return nil }
        switch kind {
        case .cpu: return profile.cpuTree(thread: thread)
        case .allocations: return profile.allocation
        case .locks: return profile.contention
        case .gc: return nil
        }
    }

    var symbols: JavaProfileSymbols? { profile?.symbols }

    /// Hot methods of the shown tree, cached by what they were computed from.
    var hotMethods: [JavaProfileTree.HotMethod] {
        guard let tree, let symbols else { return [] }
        let key = HotKey(kind: kind, thread: thread, generation: generation, nodes: tree.nodeCount)
        if let cached = hotCache, cached.key == key { return cached.rows }
        let rows = tree.hotMethods(symbols: symbols)
        hotCache = (key, rows)
        return rows
    }

    private struct HotKey: Equatable {
        var kind: Kind
        var thread: String?
        var generation: Int
        var nodes: Int
    }

    @ObservationIgnored private var hotCache: (key: HotKey, rows: [JavaProfileTree.HotMethod])?

    /// Thread names by sample count, most samples first.
    var threadNames: [String] {
        guard let profile else { return [] }
        return profile.cpuByThread
            .sorted { $0.value.totalSamples > $1.value.totalSamples }
            .map(\.key)
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
            return "\(String(format: "%.1f", Double(total) / 1000)) ms blocked"
        case .gc:
            return ""
        }
    }

    func percent(_ count: Int) -> Double {
        guard let total = tree?.totalSamples, total > 0 else { return 0 }
        return Double(count) * 100 / Double(total)
    }

    func resetNavigation() {
        zoomStack = []
        selectedMethod = nil
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
