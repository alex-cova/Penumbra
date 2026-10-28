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
    /// Whether Fix all and Apply fix to N problems may apply this fix without asking: most fixes
    /// are local and safe in bulk, but a fix that deletes a declaration is a decision, so it runs
    /// one at a time from ⌥↩ — never from Fix all.
    public let isBatchable: Bool

    public init(title: String, edits: [Edit], isBatchable: Bool = true) {
        self.title = title
        self.edits = edits
        self.isBatchable = isBatchable
    }
}

extension SwiftInspectionFix {
    /// The whole line holding `range`, through its line break (or to the file's end), for a fix that
    /// deletes a declaration. `nil` when other code shares the line (`private var a = 1; f()`):
    /// deleting the line would delete code. A trailing comment goes with the declaration, as
    /// organize-imports does for imports.
    static func lineDeleting(_ range: Range<Int>, in text: String) -> Range<Int>? {
        lineDeleting(range, in: Array(text.utf8))
    }

    /// The same over the file's bytes, for passes that walk `utf8` without keeping the text.
    static func lineDeleting(_ range: Range<Int>, in utf8: [UInt8]) -> Range<Int>? {
        guard !utf8.isEmpty, range.lowerBound <= utf8.count, range.upperBound <= utf8.count else { return nil }
        var start = range.lowerBound
        while start > 0, utf8[start - 1] != 10, utf8[start - 1] != 13 { start -= 1 }
        var end = range.upperBound
        while end < utf8.count, utf8[end] != 10, utf8[end] != 13 { end += 1 }
        let line = String(decoding: utf8[start..<end], as: UTF8.self)
        // The declaration's own text is on this line by construction; anything else must be
        // whitespace or a trailing comment.
        let before = line.prefix(range.lowerBound - start)
        guard before.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        let after = line.suffix(end - range.upperBound).trimmingCharacters(in: .whitespaces)
        guard isTrailingCommentOnly(after) else { return nil }
        if end < utf8.count {
            if utf8[end] == 13, end + 1 < utf8.count, utf8[end + 1] == 10 {
                end += 2
            } else {
                end += 1
            }
        } else if start > 0 {
            start -= 1
        }
        return start ..< end
    }

    /// Whitespace, a `//` comment (which runs to the line's end), or a `/* … */` comment followed by
    /// whitespace only: anything else is code the fix must not delete.
    private static func isTrailingCommentOnly(_ after: String) -> Bool {
        if after.isEmpty { return true }
        if after.hasPrefix("//") { return true }
        if after.hasPrefix("/*"), let end = after.range(of: "*/") {
            return after[end.upperBound...].allSatisfy { $0 == " " || $0 == "\t" }
        }
        return false
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
