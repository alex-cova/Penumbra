@preconcurrency import AppKit
import Foundation

/// A click in the gutter's line-number or decoration column that no decoration handled, reported
/// through ``TextView/gutterLineClickHandler``.
public struct GutterLineClick {
    /// 1-based document line.
    public let line: Int
    /// A right click or a Control-click, which should open a menu rather than act.
    public let isSecondary: Bool
    /// The mouse-down event, for positioning a menu or popover at the click.
    public let event: NSEvent
    /// The decoration a secondary click landed on in the decoration or line-marker column (a run
    /// button); `nil` on a line number, even one a decoration replaces.
    public let decoration: GutterDecoration?

    public init(line: Int, isSecondary: Bool, event: NSEvent, decoration: GutterDecoration? = nil) {
        self.line = line
        self.isSecondary = isSecondary
        self.event = event
        self.decoration = decoration
    }
}

/// Where the editor's context menu was opened, passed to ``TextView/contextMenuItemsProvider``.
public struct EditorContextMenuContext {
    /// UTF-16 offset of the click, or of the caret when the menu was opened from the keyboard.
    public let location: Int?
    /// The selection when the menu opened (after a right click moved the caret, if it did).
    public let selectedRange: NSRange?

    public init(location: Int?, selectedRange: NSRange?) {
        self.location = location
        self.selectedRange = selectedRange
    }
}
