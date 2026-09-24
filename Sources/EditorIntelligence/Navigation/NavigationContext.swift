import Foundation

/// What kind of navigation the editor is asking for, so a provider that serves several
/// (`SymbolIndex`-backed lookup, LSP) can answer the right request.
public enum NavigationKind: Sendable {
    case definition
    case implementation
    /// The method a method overrides or implements, or the supertypes of a class.
    case superMethod
    case references
}

/// Context passed to navigation providers when the editor requests navigation.
public struct NavigationContext: Sendable, CustomStringConvertible {
    public let document: Document
    public let cursor: Cursor
    public let selection: Selection
    public let trigger: RequestTrigger
    public let kind: NavigationKind

    public init(
        document: Document,
        cursor: Cursor,
        selection: Selection,
        trigger: RequestTrigger = .manual,
        kind: NavigationKind = .definition
    ) {
        self.document = document
        self.cursor = cursor
        self.selection = selection
        self.trigger = trigger
        self.kind = kind
    }

    public var description: String {
        "Navigation in \(document.displayName) at \(cursor.position)"
    }
}
