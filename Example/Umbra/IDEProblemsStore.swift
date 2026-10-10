import EditorIntelligence
import Foundation
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

    private(set) var editorDiagnostics: [URL: [Diagnostic]] = [:]
    private(set) var compilerDiagnostics: [URL: [Diagnostic]] = [:]
    private(set) var inspectionDiagnostics: [URL: [Diagnostic]] = [:]
    /// Build-system sources `setBuildDiagnostics(_:source:)` is called with. Each project system
    /// owns its own bucket, so a SwiftPM build never replaces Gradle's results or the reverse.
    static let gradleBuildSource = "gradle"
    static let swiftPMBuildSource = "swiftpm"

    /// Errors and warnings parsed from the last task run of each build system, kept apart from
    /// `compilerDiagnostics` because an editor report rewrites a file's `javac` entry. A file's
    /// entry is dropped once the file is saved, when the in-editor compile takes over.
    private var buildBySource: [String: [URL: [Diagnostic]]] = [:]

    /// Every source's build problems, merged per file (sources in name order, so it is stable).
    var buildDiagnostics: [URL: [Diagnostic]] {
        var merged: [URL: [Diagnostic]] = [:]
        for source in buildBySource.keys.sorted() {
            for (url, diagnostics) in buildBySource[source] ?? [:] {
                merged[url, default: []].append(contentsOf: diagnostics)
            }
        }
        return merged
    }
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

    var errorCount: Int { DiagnosticGrouping.counts(in: allFiles).errors }
    var warningCount: Int { DiagnosticGrouping.counts(in: allFiles).warnings }
    var isEmpty: Bool {
        editorDiagnostics.isEmpty && compilerDiagnostics.isEmpty && inspectionDiagnostics.isEmpty && buildBySource.isEmpty
    }

    /// Takes an active editor's report. Compiler results in it are the service's cached ones for
    /// that file (which is how a re-opened file gets its problems back); the rest are the editor's.
    func setEditorDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        let key = url.standardizedFileURL
        let own = diagnostics.filter { $0.source != Self.compilerSource && $0.source != Self.inspectionSource }
        editorDiagnostics[key] = own.isEmpty ? nil : own
        setCompilerDiagnostics(diagnostics.filter { $0.source == Self.compilerSource }, for: key)
    }

    func clearEditorDiagnostics(for url: URL) {
        editorDiagnostics[url.standardizedFileURL] = nil
    }

    func setCompilerDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        let key = url.standardizedFileURL
        if diagnostics.isEmpty {
            compilerDiagnostics[key] = nil
        } else {
            compilerDiagnostics[key] = diagnostics
        }
    }

    func setInspectionDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        let key = url.standardizedFileURL
        inspectionDiagnostics[key] = diagnostics.isEmpty ? nil : diagnostics
    }

    /// Replaces `source`'s listed build problems with the ones from the run that just finished.
    /// Other sources' problems stay.
    func setBuildDiagnostics(_ diagnostics: [URL: [Diagnostic]], source: String) {
        var bucket: [URL: [Diagnostic]] = [:]
        for (url, list) in diagnostics where !list.isEmpty {
            bucket[url.standardizedFileURL, default: []].append(contentsOf: list)
        }
        buildBySource[source] = bucket.isEmpty ? nil : bucket
    }

    /// Drops a file's build problems from every source, or all of them with no URL.
    func clearBuildDiagnostics(for url: URL? = nil) {
        if let url {
            let key = url.standardizedFileURL
            for source in Array(buildBySource.keys) {
                buildBySource[source]?[key] = nil
                if buildBySource[source]?.isEmpty == true { buildBySource[source] = nil }
            }
        } else {
            buildBySource = [:]
        }
    }

    func clearCompilerDiagnostics() {
        compilerDiagnostics = [:]
    }

    func toggleSeverity(_ severity: DiagnosticSeverity) {
        if visibleSeverities.contains(severity) {
            visibleSeverities.remove(severity)
        } else {
            visibleSeverities.insert(severity)
        }
    }
}
