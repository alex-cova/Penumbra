import Foundation
import JavaIntelligence
import Observation

@MainActor
@Observable
final class IDEGradleTestPresentation {
    struct Row: Identifiable, Sendable {
        let id: String
        let title: String
        let depth: Int
        let outcome: GradleTestEvent.Outcome?
        let duration: Int64?
        let hasChildren: Bool
    }

    struct SavedReports: Codable, Sendable {
        let rows: [GradleTestReports.Row]
        let html: [GradleTestReports.HTMLReport]

        static let empty = Self(rows: [], html: [])
    }

    private(set) var summary: GradleTestHistory.Summary?
    private(set) var history: [GradleTestHistory.Summary] = []
    private(set) var counts: [GradleTestEvent.Outcome: Int] = [:]
    private(set) var issues = 0
    private(set) var status: String?
    private(set) var reportCounts: [GradleTestEvent.Outcome: Int] = [:]
    private(set) var reports = SavedReports.empty
    private(set) var rows: [Row] = []
    private(set) var failureRows: [String] = []
    private(set) var isRestoring = false
    var selected: Set<String> = []
    var query = "" { didSet { scheduleProjection() } }
    var hidePassed = false { didSet { scheduleProjection() } }
    var failedOnly = false { didSet { scheduleProjection() } }
    var includesWorkers = false { didSet { scheduleProjection() } }
    var collapsed: Set<String> = [] { didSet { scheduleProjection() } }

    @ObservationIgnored private var nodes: [String: GradleTestSession.Node] = [:]
    @ObservationIgnored private var projection: Task<Void, Never>?
    @ObservationIgnored private var pinned: UUID?
    @ObservationIgnored private var restoreVersion = 0

    var isRunning: Bool { summary?.state == .running }
    var primarySelection: String? { selected.count == 1 ? selected.first : nil }
    var sessionDirectory: URL? { summary.map { GradleTestHistory.shared.directory(for: $0.id) } }

    func begin(_ session: GradleTestHistory.Summary) {
        restoreVersion += 1
        isRestoring = false
        setPin(session.id)
        summary = session
        resetRows()
        status = "Waiting for Gradle test events"
    }

    func ingest(_ update: GradleTestSession.Update, for id: UUID) {
        guard summary?.id == id else { return }
        for node in update.nodes { nodes[node.id] = node }
        counts = update.counts
        issues = update.issues
        if !update.nodes.isEmpty { scheduleProjection() }
    }

    func finish(_ session: GradleTestHistory.Summary, reports: SavedReports) {
        guard summary?.id == session.id else { return }
        summary = session
        status = session.message
        self.reports = reports
        reportCounts = reports.rows.reduce(into: [:]) { counts, row in
            let status = GradleTestEvent.Outcome(rawValue: row.result.status.rawValue) ?? .unknown
            counts[status, default: 0] += 1
        }
        scheduleProjection()
    }

    func refreshHistory(root: URL) async {
        history = await GradleTestHistory.shared.list(root: root)
    }

    func restore(_ session: GradleTestHistory.Summary) async {
        guard !isRunning, session.state != .running else { return }
        restoreVersion += 1
        let version = restoreVersion
        isRestoring = true
        let history = GradleTestHistory.shared
        guard await history.acquire(session.id) else {
            if version == restoreVersion { isRestoring = false }
            return
        }
        let directory = history.directory(for: session.id)
        let journal = GradleTestSession(id: session.id, directory: directory)
        let update = await journal.seal(unfinished: session.state == .cancelled ? .cancelled : .unknown)
        let saved = await Task.detached {
            let url = directory.appendingPathComponent("reports.json")
            guard let data = try? Data(contentsOf: url) else { return SavedReports.empty }
            return (try? JSONDecoder().decode(SavedReports.self, from: data)) ?? .empty
        }.value
        guard version == restoreVersion, !Task.isCancelled else {
            await history.release(session.id)
            if version == restoreVersion { isRestoring = false }
            return
        }
        releasePin()
        pinned = session.id
        summary = session
        resetRows()
        ingest(update, for: session.id)
        finish(session, reports: saved)
        isRestoring = false
    }

    func clear() {
        restoreVersion += 1
        isRestoring = false
        releasePin()
        summary = nil
        history = []
        status = nil
        resetRows()
    }

    func detail(for id: String) -> GradleTestSession.Node? { nodes[id] }
    func reportRow(for id: String) -> GradleTestReports.Row? { reports.rows.first { $0.id == id } }

    func failedTests() -> [GradleTestSession.Node] { nodes.values.filter { $0.isTest && $0.outcome == .failed } }

    func selectedTests() -> [GradleTestSession.Node] {
        var targets: [GradleTestSession.Node] = []
        for node in nodes.values where node.isTest && node.outcome != .running {
            if selected.contains(node.id) {
                targets.append(node)
            } else if let task = node.event.task, selected.contains(Self.taskKey(node.event.build, task))
                        || selected.contains(Self.moduleKey(node.event.build, node.event.module ?? ":"))
                        || selected.contains(Self.buildKey(node.event.build)) {
                targets.append(node)
            } else {
                var parent = node.event.parentID
                var visited: Set<String> = []
                while let id = parent, visited.insert(id).inserted {
                    if selected.contains(id) { targets.append(node); break }
                    parent = nodes[id]?.event.parentID
                }
            }
        }
        return targets
    }

    func showPreviousResult(for declaration: JavaTestClass, method: JavaTestMethod?) {
        let build = summary.map { GradleBuildIdentity.canonicalPath($0.root) }
        let candidates = nodes.values.filter { node in
            let event = node.event
            guard node.isTest, event.task == declaration.gradleTaskPath,
                  event.build == build,
                  let actual = event.className else { return false }
            let expected = method?.className ?? declaration.qualifiedName
            guard actual.replacingOccurrences(of: "$", with: ".") == expected.replacingOccurrences(of: "$", with: ".")
            else { return false }
            guard let method else { return true }
            return (event.methodName ?? event.name) == method.methodName
        }
        guard let node = candidates.sorted(by: { $0.event.sequence < $1.event.sequence }).first else {
            showActionMessage("No previous result matched this test in the selected Gradle run.")
            return
        }
        query = ""
        failedOnly = false
        hidePassed = false
        collapsed = []
        selected = [node.id]
    }

    func showActionMessage(_ message: String) { status = message }

    func selectFailure(increment: Int) {
        guard !failureRows.isEmpty else { return }
        let current = primarySelection.flatMap { failureRows.firstIndex(of: $0) } ?? (increment > 0 ? -1 : 0)
        selected = [failureRows[(current + increment + failureRows.count) % failureRows.count]]
    }

    private func setPin(_ id: UUID) {
        releasePin()
        pinned = id
        Task {
            let acquired = await GradleTestHistory.shared.acquire(id)
            if acquired, pinned != id { await GradleTestHistory.shared.release(id) }
        }
    }

    private func releasePin() {
        if let pinned {
            self.pinned = nil
            Task { await GradleTestHistory.shared.release(pinned) }
        }
    }

    private func resetRows() {
        projection?.cancel()
        projection = nil
        nodes = [:]
        reports = .empty
        rows = []
        failureRows = []
        counts = [:]
        reportCounts = [:]
        issues = 0
        selected = []
        collapsed = []
    }

    private func scheduleProjection() {
        // Let one projection finish before observing another change. Sustained event traffic
        // should refresh the outline as each snapshot finishes.
        guard projection == nil else { projectionWasInvalidated = true; return }
        projection = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self, !Task.isCancelled else { return }
            let input = Input(nodes: self.nodes, reports: self.reports.rows, root: self.summary?.root.path,
                              query: self.query, hidePassed: self.hidePassed, failedOnly: self.failedOnly,
                              includesWorkers: self.includesWorkers, collapsed: self.collapsed)
            let projected = await Self.project(input)
            guard !Task.isCancelled else { return }
            self.rows = projected
            self.failureRows = projected.filter { !$0.hasChildren && $0.outcome == .failed }.map(\.id)
            self.projection = nil
            if input.query != self.query || input.hidePassed != self.hidePassed || input.failedOnly != self.failedOnly
                || input.includesWorkers != self.includesWorkers || input.collapsed != self.collapsed
                || self.projectionWasInvalidated {
                self.projectionWasInvalidated = false
                self.scheduleProjection()
            }
        }
        projectionWasInvalidated = false
    }

    @ObservationIgnored private var projectionWasInvalidated = false

    private struct Input: Sendable {
        let nodes: [String: GradleTestSession.Node]
        let reports: [GradleTestReports.Row]
        let root: String?
        let query: String
        let hidePassed: Bool
        let failedOnly: Bool
        let includesWorkers: Bool
        let collapsed: Set<String>
    }

    private struct Branch: Sendable {
        let id: String
        let title: String
        let parent: String?
        let outcome: GradleTestEvent.Outcome?
        let duration: Int64?
    }

    private nonisolated static func buildKey(_ build: String) -> String { "build\0" + build }
    private nonisolated static func moduleKey(_ build: String, _ module: String) -> String { "module\0" + build + "\0" + module }
    private nonisolated static func taskKey(_ build: String, _ task: String) -> String { "task\0" + build + "\0" + task }

    @concurrent private static func project(_ input: Input) async -> [Row] {
        var branches: [String: Branch] = [:]
        var children: [String: [String]] = [:]
        let workspace = input.root ?? ""
        func add(_ id: String, _ title: String, _ parent: String?, _ outcome: GradleTestEvent.Outcome? = nil, _ duration: Int64? = nil) {
            guard branches[id] == nil else { return }
            branches[id] = Branch(id: id, title: title, parent: parent, outcome: outcome, duration: duration)
            children[parent ?? "", default: []].append(id)
        }
        func taskParent(_ build: String, _ module: String, _ task: String) -> String {
            let buildID = buildKey(build)
            let moduleID = moduleKey(build, module)
            let taskID = taskKey(build, task)
            add(buildID, URL(fileURLWithPath: build).lastPathComponent, nil)
            add(moduleID, module == ":" ? "Root module" : module, buildID)
            add(taskID, task.split(separator: ":").last.map(String.init) ?? task, moduleID)
            return taskID
        }
        func testAllowed(_ outcome: GradleTestEvent.Outcome, _ name: String) -> Bool {
            if input.failedOnly, outcome != .failed, outcome != .aborted { return false }
            if input.hidePassed, outcome == .passed { return false }
            return input.query.isEmpty || name.localizedCaseInsensitiveContains(input.query)
        }
        func ancestors(of node: GradleTestSession.Node, base: String) -> String {
            var chain: [GradleTestSession.Node] = []
            var visited: Set<String> = [node.id]
            var parent = node.event.parentID
            while let id = parent, let ancestor = input.nodes[id], ancestor.isSuite, visited.insert(id).inserted, chain.count < 100 {
                if input.includesWorkers || ancestor.event.className != nil { chain.append(ancestor) }
                parent = ancestor.event.parentID
            }
            var result = base
            for ancestor in chain.reversed() {
                add(ancestor.id, ancestor.event.name ?? "Suite", result, ancestor.outcome, ancestor.event.durationMs)
                result = ancestor.id
            }
            return result
        }
        for node in input.nodes.values {
            if Task.isCancelled { return [] }
            let event = node.event
            guard let task = event.task else { continue }
            let searchable = [event.build, event.module, event.task, event.className, event.name].compactMap { $0 }.joined(separator: " ")
            if node.isTest {
                guard testAllowed(node.outcome, searchable) else { continue }
                let base = taskParent(event.build, event.module ?? ":", task)
                var parent = ancestors(of: node, base: base)
                if parent == base, let type = event.className {
                    let id = base + "\0class\0" + type
                    add(id, type, base)
                    parent = id
                }
                if let method = event.methodName, method != event.name {
                    let id = parent + "\0method\0" + method
                    add(id, method, parent)
                    parent = id
                }
                add(node.id, event.name ?? "Test", parent, node.outcome, event.durationMs)
            } else if node.isSuite, event.failure != nil, testAllowed(node.outcome, searchable) {
                let base = taskParent(event.build, event.module ?? ":", task)
                add(node.id, event.name ?? "Suite", ancestors(of: node, base: base), node.outcome, event.durationMs)
            } else if event.kind == .taskFinished, node.outcome == .failed, event.failure != nil,
                      !input.failedOnly, input.query.isEmpty {
                let base = taskParent(event.build, event.module ?? ":", task)
                add(node.id, "Task failure", base, node.outcome)
            }
        }
        for report in input.reports {
            let item = report.result
            let outcome = GradleTestEvent.Outcome(rawValue: item.status.rawValue) ?? .unknown
            guard testAllowed(outcome, report.task + " " + item.className + " " + item.name) else { continue }
            let module = report.task.split(separator: ":").dropLast().joined(separator: ":")
            let base = taskParent(workspace, ":" + module, report.task)
            let group = base + "\0class\0" + item.className
            add(group, item.className, base)
            let duration = item.duration.isFinite && item.duration >= 0 && item.duration < 1e12 ? Int64(item.duration * 1000) : nil
            add(report.id, item.name, group, outcome, duration)
        }
        var result: [Row] = []
        func appendChildren(_ parent: String, depth: Int) {
            let items = (children[parent] ?? []).compactMap { branches[$0] }.sorted {
                if $0.title == $1.title { return $0.id < $1.id }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            for branch in items {
                let expandable = children[branch.id] != nil
                result.append(Row(id: branch.id, title: branch.title, depth: depth, outcome: branch.outcome,
                                  duration: branch.duration, hasChildren: expandable))
                if expandable, !input.collapsed.contains(branch.id) { appendChildren(branch.id, depth: depth + 1) }
            }
        }
        appendChildren("", depth: 0)
        return result
    }
}
