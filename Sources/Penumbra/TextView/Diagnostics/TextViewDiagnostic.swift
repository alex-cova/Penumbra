import Foundation

/// A diagnostic range rendered as a squiggle in the text view.
public struct TextViewDiagnostic: Equatable, Sendable, Identifiable {
    public let id: String
    public let range: NSRange
    public let severity: TextViewDiagnosticSeverity
    /// What is wrong, shown in the hover tooltip and by Show Error Description. Empty when the
    /// host only wants the squiggle.
    public let message: String
    /// The tool that reported it ("java-inspection", "javac"…), shown after the message.
    public let source: String?

    public init(id: String = UUID().uuidString,
                range: NSRange,
                severity: TextViewDiagnosticSeverity,
                message: String = "",
                source: String? = nil) {
        self.id = id
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }
}
