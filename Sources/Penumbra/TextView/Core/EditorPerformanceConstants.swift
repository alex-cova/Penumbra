import Foundation

/// Performance guardrails for editor features outside tree-sitter parsing.
public enum EditorPerformanceConstants {
    /// Line count above which ``FoldingController`` skips a full-document fold scan.
    ///
    /// A synchronous pass over every line (reading indentation from the buffer) freezes the UI on
    /// generated tree-sitter grammars such as `parser.c`. Folding stays enabled, but no regions are
    /// computed until the document shrinks below this threshold.
    nonisolated(unsafe) public static var maxFoldRecomputeLineCount = 50_000
    /// Fewest `LineController`s kept before layout evicts those far from the viewport. Each holds a
    /// line's typesetting (~6 KB); without a bound, scrolling through a 120k-line file kept ~900 MB.
    /// The effective cap is the larger of this and 8× the lines currently laid out.
    nonisolated(unsafe) public static var minimumRetainedLineControllers = 1_024
}
