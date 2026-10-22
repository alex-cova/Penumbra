import EditorIntelligence
import Foundation
import JavaIntelligence
import Observation

/// What the Problems tab lists: diagnostics from the active editors (duplicate symbols, LSP…) and
/// from the Java compiler, merged per file. The grouping and sorting itself is
/// `DiagnosticGrouping`, so this stays a thin observable holder.
@MainActor
@Observable
final class IDEProblemsStore {
    /// Source name the Java compiler reports under; its diagnostics are kept apart from the
    /// editor's so a compile result is never listed twice.
    static let compilerSource = "javac"
    static let inspectionSource = "java-inspection"

    /// Every diagnostic bucket, keyed by source (`editor`, `javac`, `java-inspection`, `gradle`,
    /// `swiftpm`, …). An editor report rewrites only that file's `javac` entry. A build source
    /// never replaces another source.
    private var bySource: [String: [URL: [Diagnostic]]] = [:]
    private var staleByFile: [URL: Set<String>] = [:]
    private var reportedFiles: Set<URL> = []
    /// How many editor reports have landed per file, and what that count was when the agent last
    /// changed the file: a later count means the editor has analysed the agent's text.
    private var editorReportCounts: [URL: Int] = [:]
    private var agentEditBaselines: [URL: Int] = [:]
    private static let editorSource = "editor"

    var editorDiagnostics: [URL: [Diagnostic]] { bySource[Self.editorSource] ?? [:] }
    var compilerDiagnostics: [URL: [Diagnostic]] { bySource[Self.compilerSource] ?? [:] }
    var inspectionDiagnostics: [URL: [Diagnostic]] { bySource[Self.inspectionSource] ?? [:] }
    /// Build-system sources `setBuildDiagnostics(_:source:)` is called with. Each project system
    /// owns its own bucket, so a SwiftPM build never replaces Gradle's results or the reverse.
    static let gradleBuildSource = "gradle"
    static let mavenBuildSource = "maven"
    static let swiftPMBuildSource = "swiftpm"
    static let xcodeBuildSource = "xcode"
    /// The builds a SwiftUI preview runs: their own bucket, so a preview never replaces a package build's problems.
    static let swiftUIPreviewBuildSource = "swiftui-preview"

    /// Every source's build problems, merged per file (sources in name order, so it is stable).
    /// Editor, javac and inspection buckets are not build output.
    var buildDiagnostics: [URL: [Diagnostic]] {
        var merged: [URL: [Diagnostic]] = [:]
        for source in bySource.keys.sorted() where !Self.isLanguageSource(source) {
            for (url, diagnostics) in bySource[source] ?? [:] {
                merged[url, default: []].append(contentsOf: diagnostics)
            }
        }
        return merged
    }

    private static func isLanguageSource(_ source: String) -> Bool {
        source == editorSource || source == compilerSource || source == inspectionSource
    }

    /// Project-level messages from the last Gradle run (failed tasks, dependency errors, test summary).
    private(set) var buildMessages: [GradleProblem] = []
    /// Called when the user opens a test-failure summary from the Problems list.
    var onShowTestResults: (() -> Void)?

    var visibleSeverities: Set<DiagnosticSeverity> = [.error, .warning, .information, .hint]

    /// Every file with problems, ignoring the severity filter -- the basis for the badge counts.
    private var allFiles: [ProblemFile] {
        DiagnosticGrouping.files(from: [editorDiagnostics, compilerDiagnostics, inspectionDiagnostics, buildDiagnostics])
    }

    /// Files to list, after the severity filter.
    var files: [ProblemFile] {
        DiagnosticGrouping.files(
            from: [editorDiagnostics, compilerDiagnostics, inspectionDiagnostics, buildDiagnostics],
            severities: visibleSeverities
        )
    }

    /// Error, warning and weaker (information, hint) counts of one file across every source, ignoring
    /// the severity filter: what the editor's inspection widget shows.
    func counts(for url: URL) -> (errors: Int, warnings: Int, weaker: Int) {
        let key = url.standardizedFileURL
        let buckets = [editorDiagnostics, compilerDiagnostics, inspectionDiagnostics, buildDiagnostics]
            .map { source in source.filter { $0.key == key } }
        let rows = DiagnosticGrouping.files(from: buckets).flatMap(\.rows)
        return (
            rows.filter { $0.diagnostic.severity == .error }.count,
            rows.filter { $0.diagnostic.severity == .warning }.count,
            rows.filter { $0.diagnostic.severity == .information || $0.diagnostic.severity == .hint }.count
        )
    }

    var errorCount: Int {
        DiagnosticGrouping.counts(in: allFiles).errors + buildMessages.filter { $0.severity == .error }.count
    }
    var warningCount: Int {
        DiagnosticGrouping.counts(in: allFiles).warnings + buildMessages.filter { $0.severity == .warning }.count
    }
    var isEmpty: Bool { bySource.isEmpty && staleByFile.isEmpty && buildMessages.isEmpty }

    var visibleBuildMessages: [GradleProblem] {
        buildMessages.filter { message in
            switch message.severity {
            case .error: visibleSeverities.contains(.error)
            case .warning: visibleSeverities.contains(.warning)
            case .info: visibleSeverities.contains(.information)
            }
        }
    }

    func setBuildMessages(_ messages: [GradleProblem]) {
        buildMessages = messages
    }

    /// Takes an active editor's report. Compiler results in it are the service's cached ones for
    /// that file (which is how a re-opened file gets its problems back); the rest are the editor's.
    /// Inspection diagnostics in the same report are left in their own bucket.
    /// An empty report still counts as a report: the file was analysed and is clean, which
    /// the widget must tell apart from "no report yet".
    func setEditorDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        let key = url.standardizedFileURL
        let own = diagnostics.filter { $0.source != Self.compilerSource && $0.source != Self.inspectionSource }
        replace(own, for: key, source: Self.editorSource)
        replace(diagnostics.filter { $0.source == Self.compilerSource }, for: key, source: Self.compilerSource)
        reportedFiles.insert(key)
        editorReportCounts[key, default: 0] += 1
    }

    /// The agent is about to change this file: remember how many reports it has had.
    func noteAgentEdit(of url: URL) {
        let key = url.standardizedFileURL
        agentEditBaselines[key] = editorReportCounts[key, default: 0]
    }

    /// Whether the editor has reported on the file since the agent last changed it. A file the agent
    /// never changed counts as reported.
    func hasEditorReportSinceAgentEdit(for url: URL) -> Bool {
        let key = url.standardizedFileURL
        guard let baseline = agentEditBaselines[key] else { return true }
        return editorReportCounts[key, default: 0] > baseline
    }

    /// The errors the editor lists for one file right now, from its own analysis, the compiler results
    /// it holds and the inspections, in line order. A source whose rows belong to older text is left
    /// out, and so is build output (it describes the last build, not this text).
    func currentErrors(for url: URL) -> [Diagnostic] {
        let key = url.standardizedFileURL
        let stale = staleByFile[key] ?? []
        var errors: [Diagnostic] = []
        for bucket in [Self.editorSource, Self.compilerSource, Self.inspectionSource] {
            // `staleSources` names diagnostic sources (what a provider reports under), not buckets.
            errors += (bySource[bucket]?[key] ?? []).filter { $0.severity == .error && !stale.contains($0.source) }
        }
        return errors.sorted { $0.range.start.line < $1.range.start.line }
    }

    /// Whether an editor report has landed for the file, even an empty one. Service
    /// publications alone don't count: only the editor refresh says the file's current
    /// text has been analysed.
    func hasEditorReport(for url: URL) -> Bool {
        reportedFiles.contains(url.standardizedFileURL)
    }

    func clearEditorDiagnostics(for url: URL) {
        replace([], for: url.standardizedFileURL, source: Self.editorSource)
        staleByFile.removeValue(forKey: url.standardizedFileURL)
        reportedFiles.remove(url.standardizedFileURL)
    }

    func setCompilerDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        replace(diagnostics, for: url.standardizedFileURL, source: Self.compilerSource)
    }

    func setInspectionDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        replace(diagnostics, for: url.standardizedFileURL, source: Self.inspectionSource)
    }

    /// Sources whose listed rows belong to older text, per file: the provider had no fresh
    /// result when the report landed, so the panel shows the previous text's rows as pending
    /// instead of treating them as current. A file with only stale flags and no diagnostics
    /// still counts as non-empty; badge counts use diagnostics only, so pending rows never
    /// inflate them. An empty set clears the file's flags.
    func setStaleSources(_ sources: Set<String>, for url: URL) {
        let key = url.standardizedFileURL
        if sources.isEmpty {
            staleByFile.removeValue(forKey: key)
        } else {
            staleByFile[key] = sources
        }
    }

    func staleSources(for url: URL) -> Set<String> {
        staleByFile[url.standardizedFileURL] ?? []
    }

    /// One source's diagnostics for one file. An empty list clears that source for the file.
    func publish(_ publication: DiagnosticPublication) {
        replace(publication.diagnostics, for: publication.url.standardizedFileURL, source: publication.source.rawValue)
    }

    /// Replaces `source`'s listed build problems with the ones from the run that just finished.
    /// Other sources' problems stay.
    func setBuildDiagnostics(_ diagnostics: [URL: [Diagnostic]], source: String) {
        var bucket: [URL: [Diagnostic]] = [:]
        for (url, list) in diagnostics where !list.isEmpty {
            bucket[url.standardizedFileURL, default: []].append(contentsOf: list)
        }
        bySource[source] = bucket.isEmpty ? nil : bucket
    }

    /// Drops a file's build problems from every build source, or all build sources with no URL.
    /// Editor, javac and inspection buckets stay.
    func clearBuildDiagnostics(for url: URL? = nil) {
        if let url {
            let key = url.standardizedFileURL
            for source in Array(bySource.keys) where !Self.isLanguageSource(source) {
                replace([], for: key, source: source)
            }
        } else {
            for source in bySource.keys where !Self.isLanguageSource(source) {
                bySource[source] = nil
            }
            buildMessages = []
        }
    }

    func clearCompilerDiagnostics() {
        bySource[Self.compilerSource] = nil
    }

    private func replace(_ diagnostics: [Diagnostic], for key: URL, source: String) {
        var bucket = bySource[source] ?? [:]
        bucket[key] = diagnostics.isEmpty ? nil : diagnostics
        bySource[source] = bucket.isEmpty ? nil : bucket
    }

    func toggleSeverity(_ severity: DiagnosticSeverity) {
        if visibleSeverities.contains(severity) {
            visibleSeverities.remove(severity)
        } else {
            visibleSeverities.insert(severity)
        }
    }
}
