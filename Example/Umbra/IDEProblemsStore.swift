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

    private(set) var editorDiagnostics: [URL: [Diagnostic]] = [:]
    private(set) var compilerDiagnostics: [URL: [Diagnostic]] = [:]
    /// Errors and warnings parsed from the last Gradle task run, kept apart from
    /// `compilerDiagnostics` because an editor report rewrites a file's `javac` entry. A file's
    /// entry is dropped once the file is saved, when the in-editor compile takes over.
    private(set) var buildDiagnostics: [URL: [Diagnostic]] = [:]
    /// Project-level messages from the last Gradle run (failed tasks, dependency and build-script
    /// errors, the test summary): replaced on each run, cleared with the build set.
    private(set) var buildMessages: [GradleProblem] = []
    /// Called when the "Show Test Results" message is clicked; wired to the Tests tab by the host.
    var onShowTestResults: (() -> Void)?
    var visibleSeverities: Set<DiagnosticSeverity> = [.error, .warning, .information, .hint]

    /// Every file with problems, ignoring the severity filter -- the basis for the badge counts.
    private var allFiles: [ProblemFile] {
        DiagnosticGrouping.files(from: [editorDiagnostics, compilerDiagnostics, buildDiagnostics])
    }

    /// Files to list, after the severity filter.
    var files: [ProblemFile] {
        DiagnosticGrouping.files(from: [editorDiagnostics, compilerDiagnostics, buildDiagnostics], severities: visibleSeverities)
    }

    var errorCount: Int { DiagnosticGrouping.counts(in: allFiles).errors + buildMessages.filter { $0.severity == .error }.count }
    var warningCount: Int { DiagnosticGrouping.counts(in: allFiles).warnings + buildMessages.filter { $0.severity == .warning }.count }
    var isEmpty: Bool {
        editorDiagnostics.isEmpty && compilerDiagnostics.isEmpty && buildDiagnostics.isEmpty && buildMessages.isEmpty
    }

    /// Project messages to list, after the severity filter.
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
    func setEditorDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        let key = url.standardizedFileURL
        let own = diagnostics.filter { $0.source != Self.compilerSource }
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

    /// Replaces the listed build problems with the ones from the run that just finished.
    func setBuildDiagnostics(_ diagnostics: [URL: [Diagnostic]]) {
        buildDiagnostics = Dictionary(
            uniqueKeysWithValues: diagnostics.filter { !$0.value.isEmpty }.map { ($0.key.standardizedFileURL, $0.value) }
        )
    }

    func clearBuildDiagnostics(for url: URL? = nil) {
        if let url {
            buildDiagnostics[url.standardizedFileURL] = nil
        } else {
            buildDiagnostics = [:]
            buildMessages = []
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
