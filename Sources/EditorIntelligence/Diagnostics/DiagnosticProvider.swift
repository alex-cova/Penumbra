import Foundation

/// A provider that produces diagnostics for a document.
public protocol DiagnosticProvider: Sendable {
    /// Human-readable provider name, used for tracing.
    var name: String { get }

    /// Produce diagnostics for the given document.
    func diagnostics(for document: Document) async -> [Diagnostic]

    /// Produce diagnostics plus the sources whose results belong to older text. Providers
    /// whose results are always computed from the given document keep the default.
    func diagnosticsWithFreshness(for document: Document) async -> (diagnostics: [Diagnostic], staleSources: Set<String>)
}

public extension DiagnosticProvider {
    func diagnosticsWithFreshness(for document: Document) async -> (diagnostics: [Diagnostic], staleSources: Set<String>) {
        (await diagnostics(for: document), [])
    }
}
