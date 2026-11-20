import Foundation
import JavaIntelligence
import Observation

/// One instance in the instance list.
struct IDEHeapInstanceRow: Identifiable, Hashable, Sendable {
    let id: Int32
    let address: String
    let shallow: Int
    let retained: Int64
    let preview: String?
}

/// One line of the dominator tree, flattened: an object, a "show more" line, the unreachable
/// objects, or one class of them.
struct IDEHeapDominatorRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case object(Int32)
        case more(parent: Int32, shown: Int, total: Int)
        case weaklyReachable
        case weaklyReachableClass(Int32)
        case unreachable
        case unreachableClass(Int32)
    }

    let id: String
    let kind: Kind
    let depth: Int
    let title: String
    let detail: String
    let shallow: Int64?
    let retained: Int64
    let childCount: Int
    var isExpanded = false

    var object: Int32? {
        if case .object(let n) = kind { return n }
        return nil
    }
}

/// One step of the path from the inspected object to its GC root.
struct IDEHeapPathRow: Identifiable, Hashable, Sendable {
    let id: Int
    let object: Int32
    let title: String
    /// The field of this object that holds the previous row's (nil for the first row).
    let via: String?
    let preview: String?
    /// The root records naming this object, on the last row.
    let rootKinds: String?
    /// The field holding the previous row's object is a `Reference.referent`.
    let isWeak: Bool
}

/// One thread of the dump: its object, name, state, what it alone keeps alive, and its stack.
struct IDEHeapThreadRow: Identifiable, Hashable, Sendable {
    let id: UInt32
    let object: Int32?
    let name: String
    let state: String
    let retained: Int64
    let frames: [HeapStackFrame]
}

/// A line of the selected thread's stack: a frame, or one of its locals under it.
struct IDEHeapStackRow: Identifiable, Hashable, Sendable {
    let id: Int
    let frameIndex: Int
    let text: String
    /// Set on a local's line.
    let local: Int32?
}

/// A class's instances' shortest paths to GC roots, folded from the root side.
struct IDEHeapMergedPaths: Sendable {
    struct Row: Identifiable, Hashable, Sendable {
        let id: Int
        let object: Int32
        let depth: Int
        let count: Int
        let title: String
        let isTarget: Bool
    }

    let className: String
    let objectCount: Int
    let rows: [Row]
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
        case path = "Path to GC Roots"
        case retains = "Retains"
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
    var inspectorTab: InspectorTab = .fields {
        didSet { if inspectorTab != oldValue, inspectorTab == .retains { loadRetainedSet() } }
    }
    private(set) var path: [IDEHeapPathRow] = []
    private(set) var retainedSet: [HeapIndex.ClassTotal] = []
    private(set) var retainedSetComplete = true
    private(set) var isLoadingRetainedSet = false
    private(set) var backStack: [Int32] = []

    // The dominator tree.
    private(set) var dominatorRows: [IDEHeapDominatorRow] = []
    private(set) var isLoadingDominators = false
    var selectedDominatorRow: IDEHeapDominatorRow.ID? {
        didSet {
            guard selectedDominatorRow != oldValue, let id = selectedDominatorRow,
                  let n = dominatorRows.first(where: { $0.id == id })?.object else { return }
            inspect(n, startingOver: true)
        }
    }

    // Merged paths of a class, shown in a sheet.
    var mergedPaths: IDEHeapMergedPaths?
    private(set) var isLoadingMergedPaths = false

    /// Called when an index opens or goes, so the histogram can show (or drop) retained sizes.
    @ObservationIgnored var onIndexChanged: (() -> Void)?

    // Reports (phase 4). Suspects load as soon as an index opens; the inspections when the
    // Reports view first shows (each is saved beside the index after its first run).
    private(set) var suspects: [HeapLeakSuspect]?
    private(set) var duplicateStrings: HeapDuplicateStrings?
    private(set) var wastedCollections: HeapWastedCollections?
    private(set) var zeroArrays: HeapZeroArrays?
    private(set) var isLoadingInspections = false
    private(set) var inspectionError: String?

    // Threads.
    private(set) var threads: [IDEHeapThreadRow]?
    var selectedThread: UInt32? {
        didSet { if selectedThread != oldValue { loadStack() } }
    }
    private(set) var stackRows: [IDEHeapStackRow] = []
    var selectedStackRow: IDEHeapStackRow.ID? {
        didSet {
            guard selectedStackRow != oldValue, let id = selectedStackRow,
                  let local = stackRows.first(where: { $0.id == id })?.local else { return }
            inspect(local, startingOver: true)
        }
    }
    @ObservationIgnored private var reportTicket = 0
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
    @ObservationIgnored private var dominatorTicket = 0
    @ObservationIgnored private var retainedSetTicket = 0
    nonisolated static let dominatorPage = 100

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
        dominatorRows = []
        clearReports()
        onIndexChanged?()
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
        dominatorTicket += 1
        retainedSetTicket += 1
        reportTicket += 1
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
        clearReports()
        onIndexChanged?()
        loadSuspects()
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
                index.instances(ofGroup: group, order: .largestRetainedFirst, limit: Self.instanceLimit).map { n in
                    IDEHeapInstanceRow(
                        id: n, address: "0x" + String(index.id(of: n), radix: 16),
                        shallow: index.shallowSize(of: n, layout: layout), retained: index.retainedSize(of: n),
                        preview: index.preview(of: n)
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
        path = []
        retainedSet = []
        retainedSetComplete = true
        isLoadingObject = true
        inspectTicket += 1
        if inspectorTab == .retains { loadRetainedSet() }
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
            self.path = loaded.path
            self.isLoadingObject = false
        })
    }

    private struct Loaded: Sendable {
        let summary: String
        let className: String?
        let fields: [IDEHeapFieldRow]
        let referrers: [IDEHeapReferrerRow]
        let referrerTotal: Int
        let path: [IDEHeapPathRow]
    }

    nonisolated private static func read(_ n: Int32, in index: HeapIndex, layout: HeapObjectLayout?) -> Loaded {
        let kind = index.kind(of: n)
        var summary = ByteCountFormatter.string(fromByteCount: Int64(index.shallowSize(of: n, layout: layout)), countStyle: .memory) + " shallow"
        switch index.reachability(of: n) {
        case .strong:
            summary += " · " + ByteCountFormatter.string(fromByteCount: index.retainedSize(of: n), countStyle: .memory) + " retained"
        case .weak:
            summary += " · only weakly reachable"
        case .unreachable:
            summary += " · unreachable (garbage)"
        }
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
        let steps = index.pathToRoot(of: n, includingWeak: true)
        let path = steps.enumerated().map { position, object in
            let isLast = position == steps.count - 1
            let kinds = isLast ? index.roots(of: object).map(\.kind.rawValue) : []
            let isWeak = position > 0 && index.outbound(of: object).contains { $0.object == steps[position - 1] && $0.isWeak }
                && !index.outbound(of: object).contains { $0.object == steps[position - 1] && !$0.isWeak }
            return IDEHeapPathRow(
                id: position, object: object, title: index.title(of: object),
                via: position == 0 ? nil : index.referenceName(from: object, to: steps[position - 1]),
                preview: index.preview(of: object),
                rootKinds: kinds.isEmpty ? nil : Array(Set(kinds)).sorted().joined(separator: ", "),
                isWeak: isWeak
            )
        }
        return Loaded(summary: summary, className: className, fields: fields, referrers: referrers, referrerTotal: total, path: path)
    }

    // MARK: - Retained set

    private func loadRetainedSet() {
        guard let index, let n = inspected else { return }
        retainedSetTicket += 1
        let ticket = retainedSetTicket
        isLoadingRetainedSet = true
        track(Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { index.retainedClasses(of: n) }.value
            guard let self, self.retainedSetTicket == ticket else { return }
            self.retainedSet = result.classes
            self.retainedSetComplete = result.complete
            self.isLoadingRetainedSet = false
        })
    }

    // MARK: - Dominator tree

    /// The top of the tree: the biggest objects kept alive, then the unreachable ones. Loaded once
    /// per index, when the Dominators view first shows.
    func loadDominatorsIfNeeded() {
        guard let index, dominatorRows.isEmpty, !isLoadingDominators else { return }
        isLoadingDominators = true
        dominatorTicket += 1
        let ticket = dominatorTicket
        track(Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { () -> [IDEHeapDominatorRow] in
                var rows = Self.childRows(of: 0, from: 0, depth: 0, in: index)
                if index.weaklyReachableCount > 0 {
                    rows.append(IDEHeapDominatorRow(
                        id: "weak", kind: .weaklyReachable, depth: 0, title: "Only weakly reachable objects",
                        detail: "\(index.weaklyReachableCount.formatted()) objects only weak, soft or phantom references reach",
                        shallow: index.weaklyReachableBytes, retained: index.weaklyReachableBytes, childCount: 1
                    ))
                }
                if index.unreachableCount > 0 {
                    rows.append(IDEHeapDominatorRow(
                        id: "unreachable", kind: .unreachable, depth: 0, title: "Unreachable objects",
                        detail: "\(index.unreachableCount.formatted()) objects no strong path from a root reaches",
                        shallow: index.unreachableBytes, retained: index.unreachableBytes, childCount: 1
                    ))
                }
                return rows
            }.value
            guard let self, self.dominatorTicket == ticket else { return }
            self.dominatorRows = rows
            self.isLoadingDominators = false
        })
    }

    func toggle(_ row: IDEHeapDominatorRow) {
        guard let position = dominatorRows.firstIndex(where: { $0.id == row.id }) else { return }
        if dominatorRows[position].isExpanded {
            var end = position + 1
            while end < dominatorRows.count, dominatorRows[end].depth > row.depth { end += 1 }
            dominatorRows.removeSubrange((position + 1)..<end)
            dominatorRows[position].isExpanded = false
            return
        }
        guard let index, row.childCount > 0 else { return }
        dominatorRows[position].isExpanded = true
        let ticket = dominatorTicket
        let rowID = row.id
        track(Task { [weak self] in
            let children = await Task.detached(priority: .userInitiated) { () -> [IDEHeapDominatorRow] in
                switch row.kind {
                case .object(let n): return Self.childRows(of: n, from: 0, depth: row.depth + 1, in: index)
                case .unreachable: return Self.bucketRows(index.unreachableClasses(limit: 200), weak: false, depth: row.depth + 1)
                case .weaklyReachable: return Self.bucketRows(index.weaklyReachableClasses(limit: 200), weak: true, depth: row.depth + 1)
                default: return []
                }
            }.value
            guard let self, self.dominatorTicket == ticket,
                  let at = self.dominatorRows.firstIndex(where: { $0.id == rowID }), self.dominatorRows[at].isExpanded else { return }
            self.dominatorRows.insert(contentsOf: children, at: at + 1)
        })
    }

    /// Replaces a "show more" line with the next page of its parent's children.
    func showMore(_ row: IDEHeapDominatorRow) {
        guard let index, case .more(let parent, let shown, _) = row.kind else { return }
        let ticket = dominatorTicket
        let rowID = row.id
        track(Task { [weak self] in
            let page = await Task.detached(priority: .userInitiated) {
                Self.childRows(of: parent, from: shown, depth: row.depth, in: index)
            }.value
            guard let self, self.dominatorTicket == ticket,
                  let at = self.dominatorRows.firstIndex(where: { $0.id == rowID }) else { return }
            self.dominatorRows.replaceSubrange(at...at, with: page)
        })
    }

    nonisolated private static func childRows(of parent: Int32, from start: Int, depth: Int, in index: HeapIndex) -> [IDEHeapDominatorRow] {
        let total = index.dominatorChildCount(of: parent)
        let page = index.dominatorChildren(of: parent, range: start..<(start + dominatorPage))
        var rows = page.map { n -> IDEHeapDominatorRow in
            let preview = index.preview(of: n).map { "  \($0)" } ?? ""
            return IDEHeapDominatorRow(
                id: "o\(n)", kind: .object(n), depth: depth, title: index.className(of: n) == "java.lang.Class"
                    ? "class " + index.classes[Int(index.classIndex(of: n))].name : index.className(of: n),
                detail: "0x" + String(index.id(of: n), radix: 16) + preview,
                shallow: Int64(index.shallowSize(of: n)), retained: index.retainedSize(of: n),
                childCount: index.dominatorChildCount(of: n)
            )
        }
        let shown = start + page.count
        if shown < total {
            rows.append(IDEHeapDominatorRow(
                id: "m\(parent)-\(shown)", kind: .more(parent: parent, shown: shown, total: total), depth: depth,
                title: "Show \(min(dominatorPage, total - shown).formatted()) more of \((total - shown).formatted())",
                detail: "", shallow: nil, retained: 0, childCount: 0
            ))
        }
        return rows
    }

    nonisolated private static func bucketRows(_ totals: [HeapIndex.ClassTotal], weak: Bool, depth: Int) -> [IDEHeapDominatorRow] {
        totals.map { total in
            IDEHeapDominatorRow(
                id: (weak ? "w" : "u") + "\(total.group)",
                kind: weak ? .weaklyReachableClass(total.group) : .unreachableClass(total.group), depth: depth, title: total.name,
                detail: "\(total.count.formatted()) objects", shallow: total.bytes, retained: total.bytes, childCount: 0
            )
        }
    }

    // MARK: - Merged paths

    /// The shortest paths to GC roots of a class's instances (the 10,000 that retain most), merged.
    func showMergedPaths(for row: HeapClassRow) {
        guard let index, let group = index.groupIndex(for: row) else { return }
        isLoadingMergedPaths = true
        let name = row.name
        track(Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> IDEHeapMergedPaths in
                let objects = index.instances(ofGroup: group, order: .largestRetainedFirst, limit: 10_000)
                let nodes = index.mergedPathsToRoots(of: objects)
                let rows = nodes.map { node in
                    IDEHeapMergedPaths.Row(
                        id: node.id, object: node.object, depth: node.depth, count: node.count,
                        title: index.title(of: node.object), isTarget: node.isTarget
                    )
                }
                return IDEHeapMergedPaths(className: name, objectCount: objects.count, rows: rows)
            }.value
            guard let self else { return }
            self.isLoadingMergedPaths = false
            self.mergedPaths = result
        })
    }

    // MARK: - Reports

    private func clearReports() {
        reportTicket += 1
        suspects = nil
        duplicateStrings = nil
        wastedCollections = nil
        zeroArrays = nil
        isLoadingInspections = false
        inspectionError = nil
        threads = nil
        selectedThread = nil
        stackRows = []
    }

    private func loadSuspects() {
        guard let index else { return }
        let ticket = reportTicket
        track(Task { [weak self] in
            let found = await Task.detached(priority: .utility) { HeapLeakSuspects.find(in: index) }.value
            guard let self, self.reportTicket == ticket else { return }
            self.suspects = found
        })
    }

    /// Runs the three inspections once (off the main actor; cached on disk afterwards).
    func loadInspectionsIfNeeded() {
        guard let index, duplicateStrings == nil || wastedCollections == nil || zeroArrays == nil, !isLoadingInspections else { return }
        isLoadingInspections = true
        let ticket = reportTicket
        track(Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(HeapDuplicateStrings, HeapWastedCollections, HeapZeroArrays), Error> in
                Result {
                    (try HeapInspections.duplicateStrings(in: index), try HeapInspections.wastedCollections(in: index),
                     try HeapInspections.zeroArrays(in: index))
                }
            }.value
            guard let self, self.reportTicket == ticket else { return }
            self.isLoadingInspections = false
            switch result {
            case .success(let (strings, collections, zeros)):
                self.duplicateStrings = strings
                self.wastedCollections = collections
                self.zeroArrays = zeros
            case .failure(let error):
                self.inspectionError = String(describing: error)
            }
        })
    }

    func loadThreadsIfNeeded() {
        guard let index, threads == nil else { return }
        let ticket = reportTicket
        track(Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { () -> [IDEHeapThreadRow] in
                index.threads().map { thread in
                    IDEHeapThreadRow(
                        id: thread.id, object: thread.object,
                        name: thread.object.flatMap(index.threadName) ?? "Thread \(thread.id)",
                        state: thread.object.flatMap(index.threadState)?.rawValue ?? "",
                        retained: thread.object.map(index.retainedSize(of:)) ?? 0, frames: thread.frames
                    )
                }
                .sorted { ($0.retained, $1.name) > ($1.retained, $0.name) }
            }.value
            guard let self, self.reportTicket == ticket else { return }
            self.threads = rows
        })
    }

    private func loadStack() {
        guard let index, let selectedThread, let thread = threads?.first(where: { $0.id == selectedThread }) else {
            stackRows = []
            return
        }
        if let object = thread.object { inspect(object, startingOver: true) }
        let ticket = reportTicket
        track(Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { () -> [IDEHeapStackRow] in
                var rows: [IDEHeapStackRow] = []
                for (position, frame) in thread.frames.enumerated() {
                    rows.append(IDEHeapStackRow(id: rows.count, frameIndex: position, text: "at " + frame.description, local: nil))
                    for local in frame.locals {
                        let preview = index.preview(of: local).map { "  \($0)" } ?? ""
                        rows.append(IDEHeapStackRow(id: rows.count, frameIndex: position, text: index.title(of: local) + preview, local: local))
                    }
                }
                return rows
            }.value
            guard let self, self.reportTicket == ticket, self.selectedThread == selectedThread else { return }
            self.stackRows = rows
        })
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
