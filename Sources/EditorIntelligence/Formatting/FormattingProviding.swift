import Foundation

/// Reformats a document or a range of it. ``LSPFormattingProvider`` is one implementation; a
/// language can supply a native one.
public protocol FormattingProviding: Sendable {
    /// Whether this provider formats `document`. A provider that returns `false` is not asked to,
    /// so the editor's own fallback (re-indenting) runs instead.
    func supportsFormatting(_ document: Document) -> Bool
    /// Edits that reformat the whole document; empty when it is already formatted.
    func formatDocument(_ document: Document) async -> [TextEdit]
    /// Edits that reformat `range`; empty when it is already formatted.
    func formatSelection(in document: Document, range: TextRange) async -> [TextEdit]
}

public extension FormattingProviding {
    func supportsFormatting(_ document: Document) -> Bool {
        true
    }
}
