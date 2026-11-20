import Foundation
import JavaIntelligence
import Observation

/// One instance in the instance list.
struct IDEHeapInstanceRow: Identifiable, Hashable, Sendable {
    let id: Int32
    let address: String
    let shallow: Int
    let preview: String?
}

/// One field, static or element of the inspected object.
struct IDEHeapFieldRow: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let type: String
    let value: String
    /// The object a reference points to; nil for primitives, null and ids not in the dump.
    let target: Int32?
}

/// One object that refers to the inspected one.
struct IDEHeapReferrerRow: Identifiable, Hashable, Sendable {
    let id: Int
    let referrer: Int32
    let title: String
    let via: String
    let preview: String?
    let isWeak: Bool
}

/// The object graph of a heap dump tab (phase 2): whether there is an index, building it, the
/// instances of the histogram's selected class and an inspector with back and forward. Every
/// read of the index runs off the main actor; a result a newer request overtook is dropped.
@MainActor
@Observable
final class IDEHeapObjectExplorer {
    enum IndexState: Equatable {
        /// Not looked for yet (the census is still reading).
        case unknown
        case checking
        /// No index: Build asks for `estimatedBytes` on a volume with `availableBytes` free.
        case absent(estimatedBytes: Int64, availableBytes: Int64?)
        case building(HeapIndexBuilder.Progress)
        case ready
        case failed(String)
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case fields = "Fields"
        case referrers = "Referrers"
        var id: String { rawValue }
    }

    let url: URL
    let store: HeapIndexStore?
    private(set) var state: IndexState = .unknown
    @ObservationIgnored private(set) var index: HeapIndex?
    /// Shown in the Summary once an index is open.
    private(set) var indexFacts: (bytes: Int64, references: Int, dangling: Int, seconds: Double)?

    // Instances of the selected class.
    private(set) var groupName: String?
    private(set) var group: Int32?
    private(set) var instances: [IDEHeapInstanceRow] = []
    private(set) var instanceTotal = 0
    private(set) var isLoadingInstances = false
    var selectedInstance: Int32? {
        didSet {
            guard selectedInstance != oldValue, let selectedInstance else { return }
            inspect(selectedInstance, startingOver: true)
        }
    }

    // The inspector.
    private(set) var inspected: Int32?
    private(set) var inspectedTitle = ""
    private(set) var inspectedSummary = ""
    private(set) var inspectedClassName: String?
    private(set) var fields: [IDEHeapFieldRow] = []
    private(set) var referrers: [IDEHeapReferrerRow] = []
    private(set) var referrerTotal = 0
    /// True from a new object's pick until its fields arrive; the old ones are gone meanwhile.
    private(set) var isLoadingObject = false
    var inspectorTab: InspectorTab = .fields
    private(set) var backStack: [Int32] = []
    private(set) var forwardStack: [Int32] = []

    nonisolated static let instanceLimit = 1_000
    nonisolated static let referrerLimit = 200

    @ObservationIgnored var layout: HeapObjectLayout?
    @ObservationIgnored private var buildTask: Task<HeapIndex, Error>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var buildTicket = 0
    @ObservationIgnored private var instanceTicket = 0
    @ObservationIgnored private var inspectTicket = 0
    @ObservationIgnored private var estimatedBytes: Int64 = 0

    init(url: URL, store: HeapIndexStore?) {
        self.url = url
        self.store = store
    }

    // MARK: - The index

    /// Opens the dump's index when one is current; otherwise says what a build would cost.
    func checkExisting(estimatedBytes: Int64) {
        guard let store else {
            state = .failed("Object indexes are unavailable here.")
            return
        }
        self.estimatedBytes = estimatedBytes
        state = .checking
        buildTicket += 1
        let ticket = buildTicket
        let url = url
        track(Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> HeapIndex? in
                // Indexes of dumps that moved, changed or went are never opened again: sweep them
                // (and the least recently used past the cap), keeping this dump's.
                store.sweep(keeping: Set([try? store.directory(for: url)].compactMap { $0 }))
                return store.openExisting(for: url)
            }.value
            let available = HeapIndexStore.availableBytes(at: store.root)
            guard let self, self.buildTicket == ticket else { return }
            if let found {
                self.adopt(found)
            } else {
                self.state = .absent(estimatedBytes: estimatedBytes, availableBytes: available)
            }
        })
    }

    func build() {
        guard let store else { return }
        buildTask?.cancel()
        buildTicket += 1
        let ticket = buildTicket
        let url = url
        let layout = layout ?? .compressed
        state = .building(HeapIndexBuilder.Progress(phase: .readingClasses, fraction: 0))
        // Stored and cancelled itself: closing the tab stops the build, not only the wait for it.
        let work = Task.detached(priority: .userInitiated) {
            try await store.build(dump: url, layout: layout) { progress in
                Task { @MainActor [weak self] in self?.apply(progress, ticket: ticket) }
            }
        }
        buildTask = work
        track(Task { [weak self] in
            let result = await work.result
            guard let self, self.buildTicket == ticket else { return }
            self.buildTask = nil
            switch result {
            case .success(let index):
                self.adopt(index)
                let directory = index.directory
                Task.detached(priority: .utility) { store.sweep(keeping: [directory]) }
            case .failure(is CancellationError):
                self.state = .absent(estimatedBytes: self.estimatedBytes, availableBytes: HeapIndexStore.availableBytes(at: store.root))
            case .failure(let error as HeapIndexError):
                self.state = .failed(error.description)
            case .failure(let error as HprofError):
                self.state = .failed(error.description)
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        })
    }

    func cancelBuild() {
        buildTask?.cancel()
    }

    func deleteIndex() {
        cancelBuild()
        buildTicket += 1
        index = nil
        indexFacts = nil
        clearInstances()
        if let store {
            let url = url
            Task.detached(priority: .utility) { store.delete(for: url) }
            state = .absent(estimatedBytes: estimatedBytes, availableBytes: HeapIndexStore.availableBytes(at: store.root))
        }
    }

    /// Stops everything in flight (the tab closes).
    func cancelAll() {
        buildTask?.cancel()
        buildTask = nil
        for task in tasks { task.cancel() }
        tasks.removeAll()
        buildTicket += 1
        instanceTicket += 1
        inspectTicket += 1
    }

    private func apply(_ progress: HeapIndexBuilder.Progress, ticket: Int) {
        guard ticket == buildTicket, case .building(let current) = state, progress.fraction >= current.fraction else { return }
        state = .building(progress)
    }

    private func adopt(_ index: HeapIndex) {
        self.index = index
        state = .ready
        let facts = (index.diskBytes, index.referenceCount, index.danglingReferences, index.buildSeconds)
        indexFacts = facts
        if let pending = pendingRow {
            pendingRow = nil
            showInstances(of: pending)
        }
    }

    // MARK: - Instances

    @ObservationIgnored private var pendingRow: HeapClassRow?

    /// The instances of a histogram row (largest first), or nothing for a package row.
    func showInstances(of row: HeapClassRow?) {
        guard let row, row.kind != .package else {
            clearInstances()
            return
        }
        guard let index else {
            pendingRow = row
            return
        }
        guard let group = index.groupIndex(for: row) else {
            clearInstances()
            return
        }
        guard group != self.group else { return }
        self.group = group
        groupName = row.name
        instanceTotal = index.instanceCount(ofGroup: group)
        instances = []
        isLoadingInstances = true
        instanceTicket += 1
        let ticket = instanceTicket
        let layout = layout
        track(Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) {
                index.instances(ofGroup: group, limit: Self.instanceLimit).map { n in
                    IDEHeapInstanceRow(
                        id: n, address: "0x" + String(index.id(of: n), radix: 16),
                        shallow: index.shallowSize(of: n, layout: layout), preview: index.preview(of: n)
                    )
                }
            }.value
            guard let self, self.instanceTicket == ticket else { return }
            self.instances = rows
            self.isLoadingInstances = false
        })
    }

    private func clearInstances() {
        instanceTicket += 1
        group = nil
        groupName = nil
        instances = []
        instanceTotal = 0
        isLoadingInstances = false
    }

    // MARK: - Inspector

    /// Shows `n`; `startingOver` (a pick from the instance list) clears the history.
    func inspect(_ n: Int32, startingOver: Bool = false) {
        guard index != nil else { return }
        if startingOver {
            backStack = []
            forwardStack = []
        } else if let current = inspected, current != n {
            backStack.append(current)
            forwardStack = []
        }
        load(n)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = inspected { forwardStack.append(current) }
        load(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = inspected { backStack.append(current) }
        load(next)
    }

    private func load(_ n: Int32) {
        guard let index else { return }
        inspected = n
        inspectedTitle = index.title(of: n)
        inspectedSummary = ""
        inspectedClassName = nil
        fields = []
        referrers = []
        referrerTotal = 0
        isLoadingObject = true
        inspectTicket += 1
        let ticket = inspectTicket
        let layout = layout
        track(Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { Self.read(n, in: index, layout: layout) }.value
            guard let self, self.inspectTicket == ticket else { return }
            self.inspectedSummary = loaded.summary
            self.inspectedClassName = loaded.className
            self.fields = loaded.fields
            self.referrers = loaded.referrers
            self.referrerTotal = loaded.referrerTotal
            self.isLoadingObject = false
        })
    }

    private struct Loaded: Sendable {
        let summary: String
        let className: String?
        let fields: [IDEHeapFieldRow]
        let referrers: [IDEHeapReferrerRow]
        let referrerTotal: Int
    }

    nonisolated private static func read(_ n: Int32, in index: HeapIndex, layout: HeapObjectLayout?) -> Loaded {
        let kind = index.kind(of: n)
        var summary = ByteCountFormatter.string(fromByteCount: Int64(index.shallowSize(of: n, layout: layout)), countStyle: .memory) + " shallow"
        if kind == .objectArray || kind == .primitiveArray { summary += " · length \(index.length(of: n).formatted())" }
        if let preview = index.preview(of: n), kind == .instance { summary += " · \(preview)" }
        let className: String?
        switch kind {
        case .instance, .objectArray: className = index.className(of: n)
        case .classObject: className = index.classes[Int(index.classIndex(of: n))].name
        default: className = nil
        }
        let fields: [IDEHeapFieldRow] = ((try? index.fields(of: n)) ?? []).map { field in
            let text: String
            var target: Int32?
            switch field.value {
            case .object(let other):
                target = other
                let preview = index.preview(of: other).map { "  \($0)" } ?? ""
                text = index.title(of: other) + preview
            default:
                text = field.value.description
            }
            return IDEHeapFieldRow(id: field.id, name: field.name, type: typeName(field.type), value: text, target: target)
        }
        let total = index.inboundCount(of: n)
        let referrers = index.inbound(of: n, range: 0..<referrerLimit).enumerated().map { offset, edge in
            IDEHeapReferrerRow(
                id: offset, referrer: edge.object, title: index.title(of: edge.object),
                via: index.referenceName(from: edge.object, to: n) ?? "?",
                preview: index.preview(of: edge.object), isWeak: edge.isWeak
            )
        }
        return Loaded(summary: summary, className: className, fields: fields, referrers: referrers, referrerTotal: total)
    }

    nonisolated static func typeName(_ type: HprofBasicType) -> String {
        switch type {
        case .object: return "ref"
        case .boolean: return "boolean"
        case .char: return "char"
        case .float: return "float"
        case .double: return "double"
        case .byte: return "byte"
        case .short: return "short"
        case .int: return "int"
        case .long: return "long"
        }
    }

    private func track(_ task: Task<Void, Never>) {
        tasks.removeAll { $0.isCancelled }
        if tasks.count > 32 { tasks.removeFirst(tasks.count - 32) }
        tasks.append(task)
    }
}
