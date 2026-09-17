import Foundation

final class PlainTextInternalLanguageMode: InternalLanguageMode {
    func parse() {}

    func parseFromBuffer() {}

    func parse(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        Task { @MainActor in
            completion(true)
        }
    }

    func textDidChange(_ change: TextChange) -> LineChangeSet {
        LineChangeSet()
    }

    func tokenType(at location: Int) -> String? {
        nil
    }

    func createLineSyntaxHighlighter() -> LineSyntaxHighlighter {
        PlainTextSyntaxHighlighter()
    }

    func highestSyntaxNode(at linePosition: LinePosition) -> SyntaxNode? {
        nil
    }

    func syntaxNode(at linePosition: LinePosition) -> SyntaxNode? {
        nil
    }

    func currentIndentLevel(of line: DocumentLineNode, using indentStrategy: IndentStrategy) -> Int {
        0
    }

    func strategyForInsertingLineBreak(
        from startLinePosition: LinePosition,
        to endLinePosition: LinePosition,
        using indentStrategy: IndentStrategy) -> InsertLineBreakIndentStrategy {
        InsertLineBreakIndentStrategy(indentLevel: 0, insertExtraLineBreak: false)
    }

    func detectIndentStrategy() -> DetectedIndentStrategy {
        .unknown
    }
}
