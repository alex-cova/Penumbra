import Foundation

/// Aggregated diagnostics for a single document.
public struct DiagnosticReport: Sendable, CustomStringConvertible {
    public let documentID: DocumentID
    public let diagnostics: [Diagnostic]
    /// Sources whose diagnostics in this report belong to older text: the provider had no
    /// fresh result yet, so it answered with the previous text's findings. The host keeps
    /// its (already edit-shifted) markers for these sources instead of drawing stale ones.
    /// A source absent here with no diagnostics genuinely cleared its problems.
    public let staleSources: Set<String>

    public init(documentID: DocumentID, diagnostics: [Diagnostic], staleSources: Set<String> = []) {
        self.documentID = documentID
        self.diagnostics = diagnostics
        self.staleSources = staleSources
    }

    public var description: String {
        "DiagnosticReport(\(documentID): \(diagnostics.count) diagnostics)"
    }
}
