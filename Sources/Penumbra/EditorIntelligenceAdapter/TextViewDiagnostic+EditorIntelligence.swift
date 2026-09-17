import EditorIntelligence
import Foundation

extension TextViewDiagnostic {
    /// Creates a text-view diagnostic from an Editor Intelligence Platform diagnostic.
    public init(_ diagnostic: Diagnostic) {
        self.init(id: diagnostic.id.uuidString,
                  range: NSRange(location: diagnostic.range.start.utf16Offset,
                                 length: max(0, diagnostic.range.end.utf16Offset - diagnostic.range.start.utf16Offset)),
                  severity: TextViewDiagnosticSeverity(diagnostic.severity))
    }

    /// Resolves line/column through the live text view so LSP positions whose `utf16Offset`
    /// is only the column still land on the correct document range.
    @MainActor
    public init(_ diagnostic: Diagnostic, in textView: TextView) {
        self.init(
            id: diagnostic.id.uuidString,
            range: TextEditApplicator.nsRange(for: diagnostic.range, in: textView),
            severity: TextViewDiagnosticSeverity(diagnostic.severity)
        )
    }
}

extension TextViewDiagnosticSeverity {
    init(_ severity: DiagnosticSeverity) {
        switch severity {
        case .error:
            self = .error
        case .warning:
            self = .warning
        case .information:
            self = .information
        case .hint:
            self = .hint
        }
    }
}
