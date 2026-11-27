import Foundation

/// Context passed to hover providers when the editor requests hover information.
public struct HoverContext: Sendable, CustomStringConvertible {
    public let document: Document
    public let cursor: Cursor
    public let selection: Selection
    public let trigger: RequestTrigger
    /// True when the popup follows the mouse pointer resting on text, as opposed to a caret that
    /// rests (`.idle`) or an explicit request such as Quick Documentation. Both of the first two
    /// are ambient, so a provider may stay quiet where the popup would only repeat what is on screen.
    public let isPointerHover: Bool

    public init(
        document: Document,
        cursor: Cursor,
        selection: Selection,
        trigger: RequestTrigger = .manual,
        isPointerHover: Bool = false
    ) {
        self.document = document
        self.cursor = cursor
        self.selection = selection
        self.trigger = trigger
        self.isPointerHover = isPointerHover
    }

    public var description: String {
        "Hover in \(document.displayName) at \(cursor.position)"
    }
}
