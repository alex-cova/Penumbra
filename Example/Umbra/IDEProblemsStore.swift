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

    private(set) var editorDiagnostics: [URL: [Diagnostic]] = [:]
    private(set) var compilerDiagnostics: [URL: [Diagnostic]] = [:]
    var visibleSeverities: Set<DiagnosticSeverity> = [.error, .warning, .information, .hint]

    /// Every file with problems, ignoring the severity filter -- the basis for the badge counts.
    private var allFiles: [ProblemFile] {
        DiagnosticGrouping.files(from: [editorDiagnostics, compilerDiagnostics])
    }

    /// Files to list, after the severity filter.
    var files: [ProblemFile] {
        DiagnosticGrouping.files(from: [editorDiagnostics, compilerDiagnostics], severities: visibleSeverities)
    }

    var errorCount: Int { DiagnosticGrouping.counts(in: allFiles).errors }
    var warningCount: Int { DiagnosticGrouping.counts(in: allFiles).warnings }
    var isEmpty: Bool { editorDiagnostics.isEmpty && compilerDiagnostics.isEmpty }

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
