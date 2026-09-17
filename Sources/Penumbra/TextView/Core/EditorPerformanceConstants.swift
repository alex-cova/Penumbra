import Foundation

/// Performance guardrails for editor features outside tree-sitter parsing.
public enum EditorPerformanceConstants {
    /// Line count above which ``FoldingController`` skips a full-document fold scan.
    ///
    /// A synchronous pass over every line (reading indentation from the buffer) freezes the UI on
    /// generated tree-sitter grammars such as `parser.c`. Folding stays enabled, but no regions are
    /// computed until the document shrinks below this threshold.
    nonisolated(unsafe) public static var maxFoldRecomputeLineCount = 50_000
}
