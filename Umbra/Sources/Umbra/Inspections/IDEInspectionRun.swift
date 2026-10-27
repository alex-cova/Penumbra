import EditorIntelligence
import Foundation
import JavaIntelligence
import Observation
import SwiftIntelligence

/// One Inspect Code (or Run Inspection by Name) run: what was asked, the findings so far, and the
/// user's marks on them. Never persisted.
@MainActor
@Observable
final class IDEInspectionRun: Identifiable {
    enum State: Equatable {
        case running
        case finished
        case cancelled
    }

    /// One finding. `key` is stable across a re-inspection of its file while nothing else
    /// changed, so an exclusion survives a rerun of that file.
    struct Entry: Identifiable, Hashable {
        let key: String
        let url: URL
        let inspection: IDEInspectionFinding
        var id: String { key }
    }

    let id = UUID()
    let language: IDEInspectionLanguage
    /// The scope's short name, which the tab shows.
    let scopeTitle: String
    /// The rules a run by name was limited to, by code.
    let onlyRuleCodes: Set<String>?
    let includeProjectRules: Bool
    let profileName: String
    let createdAt = Date()

    private(set) var state: State = .running
    private(set) var done = 0
    private(set) var total = 0
    /// Findings by file, in the order they were reported.
    private(set) var results: [URL: [IDEInspectionFinding]] = [:]
    /// Entries a fix or a suppression took care of; shown struck through until hidden.
    private(set) var resolved: [Entry] = []
    var excludedKeys: Set<String> = []

    @ObservationIgnored var task: Task<Void, Never>?
    /// What was asked, so Rerun can repeat it.
    @ObservationIgnored var launch: IDEInspectionLaunch?

    init(
        language: IDEInspectionLanguage, scopeTitle: String, onlyRuleCodes: Set<String>?, includeProjectRules: Bool,
        profileName: String
    ) {
        self.language = language
        self.scopeTitle = scopeTitle
        self.onlyRuleCodes = onlyRuleCodes
        self.includeProjectRules = includeProjectRules
        self.profileName = profileName
    }

    /// A Java run, which is what the workflow was first written for.
    convenience init(scope: JavaInspectionScope, onlyRules: Set<JavaInspectionRule>?, includeProjectRules: Bool, profileName: String) {
        self.init(
            language: .java, scopeTitle: scope.title, onlyRuleCodes: onlyRules.map { Set($0.map(\.code)) },
            includeProjectRules: includeProjectRules, profileName: profileName
        )
    }

    var title: String {
        if let onlyRuleCodes, onlyRuleCodes.count == 1, let code = onlyRuleCodes.first {
            return "\(language.rule(code: code)?.title ?? code): \(scopeTitle)"
        }
        return "Inspection: \(scopeTitle)"
    }

    /// Every unresolved finding, flat, with keys.
    var entries: [Entry] {
        var all: [Entry] = []
        for (url, findings) in results {
            all.append(contentsOf: Self.entries(for: url, findings: findings))
        }
        return all
    }

    var problemCount: Int { results.values.reduce(0) { $0 + $1.count } }

    static func entries(for url: URL, findings: [IDEInspectionFinding]) -> [Entry] {
        var seen: [String: Int] = [:]
        return findings.map { finding in
            let base = "\(url.standardizedFileURL.path)|\(finding.id)|\(finding.message)"
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            return Entry(key: "\(base)|\(occurrence)", url: url, inspection: finding)
        }
    }

    // MARK: Updates (from the batch stream)

    func begin(total: Int) {
        state = .running
        self.total = total
        done = 0
        results = [:]
        resolved = []
    }

    func record(_ findings: [IDEInspectionFinding], for url: URL) {
        results[url] = findings
    }

    func record(_ findings: [JavaInspection], for url: URL) {
        record(findings.map(IDEInspectionFinding.init), for: url)
    }

    func progress(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    func finish(cancelled: Bool) {
        state = cancelled ? .cancelled : .finished
        task = nil
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Marks

    func exclude(_ keys: some Sequence<String>) { excludedKeys.formUnion(keys) }
    func include(_ keys: some Sequence<String>) { excludedKeys.subtract(keys) }

    /// A fix or suppression handled `entries`; `fresh` is what the file's inspection says now.
    func markResolved(_ handled: [Entry], newFindings fresh: [IDEInspectionFinding], for url: URL) {
        resolved.append(contentsOf: handled)
        if fresh.isEmpty { results[url] = nil } else { results[url] = fresh }
    }
}

/// A window's inspection runs and which Problems tab is showing.
@MainActor
@Observable
final class IDEInspectionRunsStore {
    enum Tab: Hashable {
        case file
        case project
        case run(UUID)
    }

    static let maxRuns = 5

    /// Inspect Code… / Run Inspection by Name… waiting for the user's scope choice.
    var pendingScopeRequest: IDEInspectCodeRequest?
    var isNamePickerPresented = false
    /// The language Run Inspection by Name starts on.
    var nameQueryLanguage: IDEInspectionLanguage = .java

    private(set) var runs: [IDEInspectionRun] = []
    var selection: Tab = .project

    func run(with id: UUID) -> IDEInspectionRun? { runs.first { $0.id == id } }

    var selectedRun: IDEInspectionRun? {
        if case .run(let id) = selection { return run(with: id) }
        return nil
    }

    func add(_ run: IDEInspectionRun) {
        runs.append(run)
        while runs.count > Self.maxRuns, let index = runs.firstIndex(where: { $0.state != .running }) {
            runs.remove(at: index)
        }
        selection = .run(run.id)
    }

    func close(_ id: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].cancel()
        runs.remove(at: index)
        if selection == .run(id) { selection = .project }
    }

    func closeAll() {
        for run in runs { run.cancel() }
        runs = []
        if case .run = selection { selection = .project }
    }
}
