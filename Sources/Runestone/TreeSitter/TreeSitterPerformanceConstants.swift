import Foundation

/// Performance guardrails for tree-sitter parsing and highlighting, adapted from CodeEditSourceEditor.
public enum TreeSitterPerformanceConstants {
    /// Maximum query matches per tree-sitter cursor invocation.
    nonisolated(unsafe) public static var matchLimit = 256

    /// Main-thread parse abort deadline (seconds). Background parses ignore this and only stop
    /// when the parse operation is cancelled.
    nonisolated(unsafe) public static var parserTimeout: TimeInterval = 0.05

    /// UTF-16 units of inserted or deleted text above which `textDidChange` skips the
    /// synchronous incremental parse. The edit is applied to the tree (`ts_tree_edit`) and a
    /// background parse is restarted, same as an in-flight parse being invalidated.
    nonisolated(unsafe) public static var maxSyncEditLength = 1024

    /// Maximum document length for synchronous operations.
    ///
    /// Also the cutoff for ``SyntaxParsePolicy/viewport``: documents at or below this UTF-16
    /// length are parsed in full so indent/outline/`syntaxNode(at:)` work everywhere.
    nonisolated(unsafe) public static var maxSyncContentLength = 1_000_000

    /// Cap on UTF-16 units included in a viewport parse of a larger document.
    nonisolated(unsafe) public static var maxViewportParseUTF16Length = 262_144

    /// Extra viewport heights parsed above and below the visible rect in viewport mode.
    nonisolated(unsafe) public static var viewportOverscanScreens: CGFloat = 2

    /// Maximum query length for synchronous highlight queries.
    nonisolated(unsafe) public static var maxSyncQueryLength = 4096

    /// UTF-16 window queried and cached for highlight captures so adjacent lines share one
    /// tree-sitter query instead of each walking the tree from the root.
    nonisolated(unsafe) public static var highlightQueryWindowUTF16Length = 32_768

    /// Concurrent operations `TreeSitterInternalLanguageMode.highlightQueue` runs at once. Visible
    /// lines are each highlighted on this queue while scrolling, so this many lines' capture
    /// windows can be in flight simultaneously — see ``captureWindowCacheSize``.
    nonisolated(unsafe) public static var highlightQueueConcurrency = 4

    /// Number of recent capture windows `TreeSitterInternalLanguageMode` keeps cached at once.
    /// Sized above ``highlightQueueConcurrency`` so concurrent lines highlighting nearby-but-distinct
    /// windows don't evict each other's cache entry before it can be reused — a single shared slot
    /// was measured to make every concurrent line recompute its own window from scratch.
    nonisolated(unsafe) public static var captureWindowCacheSize = 6

    /// Duration before a long parse is considered noteworthy (seconds).
    nonisolated(unsafe) public static var longParseTimeout: TimeInterval = 0.5

    public static let longParseNotification = Notification.Name("Runestone.longParseNotification")
    public static let longParseFinishedNotification = Notification.Name("Runestone.longParseFinishedNotification")
}
