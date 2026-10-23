import EditorIntelligence
import JavaIntelligence

/// Wraps a diagnostics provider so a dependency's source (an attached source or a decompiled class
/// opened from External Libraries or Go to Definition) is never checked: that code is for reading and
/// navigating, and problems in it are not the project's. Applied to every provider of the window's
/// `DiagnosticEngine`, including the generic ones that know nothing about Java.
struct IDEDependencyDiagnosticsFilter: DiagnosticProvider {
    let base: any DiagnosticProvider

    var name: String { base.name }

    func diagnostics(for document: Document) async -> [Diagnostic] {
        document.isDependencySource ? [] : await base.diagnostics(for: document)
    }

    func diagnosticsWithFreshness(for document: Document) async -> (diagnostics: [Diagnostic], staleSources: Set<String>) {
        document.isDependencySource ? ([], []) : await base.diagnosticsWithFreshness(for: document)
    }
}
