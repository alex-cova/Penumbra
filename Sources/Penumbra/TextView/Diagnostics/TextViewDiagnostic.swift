import Foundation

/// A diagnostic range rendered as a squiggle in the text view.
public struct TextViewDiagnostic: Equatable, Sendable, Identifiable {
    public let id: String
    public let range: NSRange
    public let severity: TextViewDiagnosticSeverity

    public init(id: String = UUID().uuidString,
                range: NSRange,
                severity: TextViewDiagnosticSeverity) {
        self.id = id
        self.range = range
        self.severity = severity
    }
}
