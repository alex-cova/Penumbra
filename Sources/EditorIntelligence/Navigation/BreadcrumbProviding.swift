import Foundation

/// A language-aware source of breadcrumb segments (the enclosing declarations at the caret),
/// used ahead of the generic symbol-index breadcrumbs.
public protocol BreadcrumbProviding: Sendable {
    /// The segments for the caret in `document`, outermost first, or `nil` when this provider
    /// does not handle the document (the generic breadcrumbs are used instead). An empty array
    /// means "handled, and the caret is in no declaration".
    func breadcrumbs(for document: Document) async -> [BreadcrumbSegment]?
}
