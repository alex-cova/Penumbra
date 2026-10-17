import Foundation

/// Diagnostic engine that aggregates, deduplicates, and sorts diagnostics from registered providers.
public actor DiagnosticEngine {
    private let providers: [DiagnosticProvider]

    public init(providers: [DiagnosticProvider]) {
        self.providers = providers
    }

    /// Collect diagnostics for the given document from all providers.
    public func diagnostics(for document: Document) async -> DiagnosticReport {
        let started = DispatchTime.now().uptimeNanoseconds
        let report = await collect(document)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000_000
        EditorPerformanceTrace.shared.record(.diagnostics, seconds: seconds)
        return report
    }

    /// One provider's answer. A named alias because the inline tuple type in
    /// `withTaskGroup(of:)` trips the repository's `SwiftAnalysis` grammar.
    private typealias CollectedDiagnostics = (diagnostics: [Diagnostic], staleSources: Set<String>)

    private func collect(_ document: Document) async -> DiagnosticReport {
        var all: [Diagnostic] = []
        var stale: Set<String> = []
        await withTaskGroup(of: CollectedDiagnostics.self) { group in
            for provider in providers {
                group.addTask {
                    await provider.diagnosticsWithFreshness(for: document)
                }
            }
            for await result in group {
                all.append(contentsOf: result.diagnostics)
                stale.formUnion(result.staleSources)
            }
        }
        let unique = Dictionary(grouping: all) { "\($0.severity)|\($0.message)|\($0.range)" }
            .values
            .map { $0.first! }
        let sorted = unique.sorted {
            if $0.severity != $1.severity {
                return $0.severity < $1.severity
            }
            return $0.range.start.utf16Offset < $1.range.start.utf16Offset
        }
        return DiagnosticReport(documentID: document.id, diagnostics: sorted, staleSources: stale)
    }
}
