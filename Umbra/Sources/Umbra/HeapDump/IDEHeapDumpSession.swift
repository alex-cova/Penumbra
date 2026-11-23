import Foundation
import JavaIntelligence
import Observation

/// One heap dump tab: reads the dump off the main actor (`HeapDumpCensus`), then holds what the
/// view asks for — mode, grouping, filter, sort and an optional layout override — and the rows
/// that follow from them, recomputed only when one of those changes.
@MainActor
@Observable
final class IDEHeapDumpSession: Identifiable {
    enum Phase: Equatable {
        case idle
        case reading(HeapDumpCensus.Progress)
        case ready
        case failed(String)
        /// A gzip'd dump (`.hprof.gz`): it must be decompressed before it can be read.
        case compressed
        case decompressing(Double)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case histogram = "Histogram"
        case dominators = "Dominators"
        case reports = "Reports"
        case threads = "Threads"
        var id: String { rawValue }
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case byClass = "Class"
        case byPackage = "Package"
        var id: String { rawValue }
    }

    let id = UUID()
    let url: URL
    let title: String
    private(set) var phase: Phase = .idle
    private(set) var overview: HeapDumpOverview?

    var mode: Mode = .summary
    var grouping: Grouping = .byClass {
        didSet {
            guard grouping != oldValue else { return }
            // Row ids of one grouping name other rows in the other, so the selection goes.
            selectedRowIDs = []
            refreshRows()
        }
    }
    var filterText = "" {
        didSet { if filterText != oldValue { refreshRows() } }
    }
    var sortOrder: [KeyPathComparator<HeapClassRow>] = [KeyPathComparator(\.shallowBytes, order: .reverse)] {
        didSet { refreshRows() }
    }
    /// A layout other than the detected one, chosen in the Summary; nil follows the detection.
    var layoutOverride: HeapObjectLayout? {
        didSet {
            guard layoutOverride != oldValue else { return }
            objects.layout = effectiveLayout
            refreshHistogram()
        }
    }
    var selectedRowIDs: Set<HeapClassRow.ID> = [] {
        didSet { if selectedRowIDs != oldValue { objects.showInstances(of: selectedClassRow) } }
    }

    /// The object graph (phase 2): index, instances, inspector.
    let objects: IDEHeapObjectExplorer

    /// The one class row selected in the histogram, grouped by class.
    var selectedClassRow: HeapClassRow? {
        guard grouping == .byClass, selectedRowIDs.count == 1, let id = selectedRowIDs.first else { return nil }
        return visibleRows.first { $0.id == id }
    }

    /// The histogram under the effective layout and grouping, before the filter.
    private(set) var histogram: HeapHistogram?
    /// What the table shows: `histogram` filtered and sorted.
    private(set) var visibleRows: [HeapClassRow] = []

    /// Opens a class's source by its Java name (`a.b.Outer$Inner`).
    @ObservationIgnored var openSource: ((String) -> Void)?
    @ObservationIgnored var openAsHex: (() -> Void)?
    @ObservationIgnored var revealInFinder: (() -> Void)?
    /// Where a compressed dump is decompressed to, and what opens the result (the workspace
    /// replaces this tab with the decompressed dump's).
    @ObservationIgnored var decompressedFolder: URL?
    @ObservationIgnored var onDecompressed: ((URL) -> Void)?
    @ObservationIgnored private var decompressTask: Task<Void, Error>?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<HeapDumpOverview, Error>?
    @ObservationIgnored private var ticket = 0
    /// Overridable in tests.
    @ObservationIgnored var reader: @Sendable (URL, @escaping @Sendable (HeapDumpCensus.Progress) -> Void) async throws -> HeapDumpOverview = {
        try await HeapDumpCensus.read($0, progress: $1)
    }

    init(url: URL, title: String, indexStore: HeapIndexStore? = nil) {
        self.url = url
        self.title = title
        objects = IDEHeapObjectExplorer(url: url, store: indexStore)
        objects.onIndexChanged = { [weak self] in self?.indexChanged() }
    }

    /// Retained size by histogram row id (class grouping), filled when an index opens.
    @ObservationIgnored private var retainedByRow: [Int: Int64] = [:]

    private func indexChanged() {
        retainedByRow = [:]
        if let index = objects.index, let overview {
            for row in overview.histogram.rows {
                if let group = index.groupIndex(for: row) { retainedByRow[row.id] = index.retainedSize(ofGroup: group) }
            }
        }
        refreshRows(regroup: false)
    }

    var effectiveLayout: HeapObjectLayout? { layoutOverride ?? overview?.layout }

    /// Reads the dump. A read in flight is replaced; its late results are dropped by ticket.
    func load() {
        if HprofGzip.isGzip(at: url) {
            // A decompressed copy newer than the archive opens at once; otherwise ask first, since
            // decompressing writes the whole dump to disk.
            if let target = decompressedTarget, Self.isNewer(target, than: url), HprofDetector.isHeapDump(at: target) {
                onDecompressed?(target)
            }
            phase = .compressed
            return
        }
        readTask?.cancel()
        task?.cancel()
        ticket += 1
        let ticket = ticket
        let url = url
        let reader = reader
        phase = .reading(HeapDumpCensus.Progress(phase: .scanningRecords, fraction: 0, bytesDone: 0, bytesTotal: 0))
        // The read itself is the task cancelled on close: awaiting a detached task from another
        // task would not pass the cancellation on, and a 6 GB read would run to its end.
        weak let owner = self
        let read = Task.detached(priority: .userInitiated) {
            try await reader(url) { progress in
                Task { @MainActor [owner] in owner?.apply(progress, ticket: ticket) }
            }
        }
        readTask = read
        task = Task { [weak self] in
            let result = await read.result
            guard let self, self.ticket == ticket, !Task.isCancelled else { return }
            self.readTask = nil
            switch result {
            case .success(let overview):
                self.overview = overview
                self.phase = .ready
                self.refreshHistogram()
                self.objects.layout = self.effectiveLayout
                if self.objects.store != nil {
                    self.objects.checkExisting(estimatedBytes: HeapIndexStore.estimatedPeakBytes(for: overview))
                }
            case .failure(let error as HprofError):
                self.phase = .failed(error.description)
            case .failure(is CancellationError):
                self.phase = .idle
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// `<folder>/<name without .gz>`.
    var decompressedTarget: URL? {
        guard let decompressedFolder else { return nil }
        var name = url.lastPathComponent
        if name.lowercased().hasSuffix(".gz") { name = String(name.dropLast(3)) }
        if !name.lowercased().hasSuffix(".hprof") { name += ".hprof" }
        return decompressedFolder.appendingPathComponent(name)
    }

    static func isNewer(_ a: URL, than b: URL) -> Bool {
        let date = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast }
        return date(a) >= date(b)
    }

    /// Decompresses to `decompressedTarget` off the main actor, then hands the result on.
    func decompress() {
        guard let target = decompressedTarget else {
            phase = .failed("There is nowhere to decompress the heap dump to.")
            return
        }
        decompressTask?.cancel()
        phase = .decompressing(0)
        let source = url
        weak let owner = self
        let work = Task.detached(priority: .userInitiated) {
            try HprofGzip.decompress(source, to: target) { fraction in
                Task { @MainActor [owner] in
                    guard let self = owner, case .decompressing(let current) = self.phase, fraction > current else { return }
                    self.phase = .decompressing(fraction)
                }
            }
        }
        decompressTask = work
        Task { [weak self] in
            let result = await work.result
            guard let self else { return }
            switch result {
            case .success:
                self.phase = .compressed
                self.onDecompressed?(target)
            case .failure(is CancellationError):
                self.phase = .compressed
            case .failure(let error as HprofGzip.Failure):
                self.phase = .failed(error.description)
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        decompressTask?.cancel()
        objects.cancelAll()
        readTask?.cancel()
        readTask = nil
        task?.cancel()
        task = nil
        ticket += 1
        if case .reading = phase { phase = .idle }
    }

    /// Workers finish out of order, so progress only moves forward.
    private func apply(_ progress: HeapDumpCensus.Progress, ticket: Int) {
        guard ticket == self.ticket, case .reading(let current) = phase else { return }
        guard progress.fraction >= current.fraction else { return }
        phase = .reading(progress)
    }

    /// Shows the histogram filtered to `name` (a Summary row's click).
    func showInHistogram(_ name: String) {
        grouping = .byClass
        filterText = name
        mode = .histogram
    }

    func openSource(of row: HeapClassRow) {
        guard let name = Self.sourceClassName(of: row) else { return }
        openSource?(name)
    }

    /// The class whose source a row stands for: an instance's class, an object array's element
    /// class; nil for primitive arrays, `Class` mirrors and packages.
    static func sourceClassName(of row: HeapClassRow) -> String? {
        switch row.kind {
        case .instance:
            return row.name
        case .objectArray:
            var name = Substring(row.name)
            while name.hasSuffix("[]") { name = name.dropLast(2) }
            return HeapClassRow.primitiveNames.contains(String(name)) ? nil : String(name)
        case .primitiveArray, .classObject, .package:
            return nil
        }
    }

    private func refreshHistogram() {
        guard let overview else {
            histogram = nil
            visibleRows = []
            return
        }
        let byClass = layoutOverride.map { overview.histogram(layout: $0) } ?? overview.histogram
        histogram = grouping == .byPackage ? byClass.groupedByPackage() : byClass
        refreshRows(regroup: false)
    }

    private func refreshRows(regroup: Bool = true) {
        if regroup, let overview {
            let byClass = layoutOverride.map { overview.histogram(layout: $0) } ?? overview.histogram
            histogram = grouping == .byPackage ? byClass.groupedByPackage() : byClass
        }
        guard let histogram else {
            visibleRows = []
            return
        }
        var rows = histogram.filtered(filterText)
        if grouping == .byClass, !retainedByRow.isEmpty {
            for position in rows.indices { rows[position].retainedBytes = retainedByRow[rows[position].id] }
        }
        visibleRows = rows.sorted(using: sortOrder)
        selectedRowIDs = selectedRowIDs.filter { id in visibleRows.contains { $0.id == id } }
    }
}
