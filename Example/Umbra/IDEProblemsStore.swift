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
    private static let editorSource = "editor"

    var editorDiagnostics: [URL: [Diagnostic]] { bySource[Self.editorSource] ?? [:] }
    var compilerDiagnostics: [URL: [Diagnostic]] { bySource[Self.compilerSource] ?? [:] }
    var inspectionDiagnostics: [URL: [Diagnostic]] { bySource[Self.inspectionSource] ?? [:] }
    /// Build-system sources `setBuildDiagnostics(_:source:)` is called with. Each project system
    /// owns its own bucket, so a SwiftPM build never replaces Gradle's results or the reverse.
    static let gradleBuildSource = "gradle"
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

    var errorCount: Int {
        DiagnosticGrouping.counts(in: allFiles).errors + buildMessages.filter { $0.severity == .error }.count
    }
    var warningCount: Int {
        DiagnosticGrouping.counts(in: allFiles).warnings + buildMessages.filter { $0.severity == .warning }.count
    }
    var isEmpty: Bool { bySource.isEmpty && buildMessages.isEmpty }

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
    func setEditorDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        let key = url.standardizedFileURL
        let own = diagnostics.filter { $0.source != Self.compilerSource && $0.source != Self.inspectionSource }
        replace(own, for: key, source: Self.editorSource)
        replace(diagnostics.filter { $0.source == Self.compilerSource }, for: key, source: Self.compilerSource)
    }

    func clearEditorDiagnostics(for url: URL) {
        replace([], for: url.standardizedFileURL, source: Self.editorSource)
    }

    func setCompilerDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        replace(diagnostics, for: url.standardizedFileURL, source: Self.compilerSource)
    }

    func setInspectionDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        replace(diagnostics, for: url.standardizedFileURL, source: Self.inspectionSource)
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
