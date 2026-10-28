import EditorIntelligence
import Foundation

/// A change that resolves a finding: one or more edits, applied together.
public struct SwiftInspectionFix: Sendable, Hashable {
    public struct Edit: Sendable, Hashable {
        /// UTF-8 byte range in the text that was inspected.
        public var bytes: Range<Int>
        public var replacement: String

        public init(bytes: Range<Int>, replacement: String) {
            self.bytes = bytes
            self.replacement = replacement
        }
    }

    public let title: String
    public let edits: [Edit]

    public init(title: String, edits: [Edit]) {
        self.title = title
        self.edits = edits
    }
}

/// One static-analysis finding in a Swift file, with the fixes that resolve it. Ranges are UTF-8 byte
/// offsets into the inspected text, the unit swift-syntax and `SwiftFileModel` share; the editor-facing
/// forms (``asDiagnostic(map:)``, ``SwiftInspectionFix/codeAction(map:)``) convert through a `SourceTextMap`.
public struct SwiftInspection: Sendable, Hashable {
    public enum Severity: String, Sendable, CaseIterable, Codable {
        case error
        case warning
        case weakWarning
        /// IntelliJ's "Consideration".
        case info
        /// IntelliJ's "No highlighting (fix available)": nothing is drawn or listed in the editor, but the fix stays
        /// on ⌥↩. Inspect Code still reports it.
        case noHighlighting
    }

    /// The rule's code (``SwiftInspectionRule/code``).
    public let id: String
    public let message: String
    public let severity: Severity
    public let bytes: Range<Int>
    public let fixes: [SwiftInspectionFix]

    public init(id: String, message: String, severity: Severity, bytes: Range<Int>, fixes: [SwiftInspectionFix] = []) {
        self.id = id
        self.message = message
        self.severity = severity
        self.bytes = bytes
        self.fixes = fixes
    }

    public static let diagnosticSource = "swift-inspection"

    func withSeverity(_ severity: Severity) -> SwiftInspection {
        SwiftInspection(id: id, message: message, severity: severity, bytes: bytes, fixes: fixes)
    }

    public func asDiagnostic(map: SourceTextMap) -> Diagnostic {
        Diagnostic(
            severity: severity.diagnosticSeverity,
            message: message,
            range: map.range(bytes: bytes),
            source: Self.diagnosticSource,
            code: id
        )
    }
}

extension SwiftInspection.Severity {
    /// The editor's four levels. A weak warning is drawn quietly, as Java's are.
    var diagnosticSeverity: DiagnosticSeverity {
        switch self {
        case .error: .error
        case .warning: .warning
        case .weakWarning: .hint
        case .info: .information
        case .noHighlighting: .hint
        }
    }
}

extension SwiftInspectionFix {
    public func codeAction(map: SourceTextMap, isPreferred: Bool = false) -> CodeAction {
        CodeAction(
            title: title,
            kind: "quickfix",
            edits: edits.map { TextEdit(range: map.range(bytes: $0.bytes), replacement: $0.replacement) },
            isPreferred: isPreferred
        )
    }
}
