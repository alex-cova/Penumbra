import Foundation

/// Build a `CompletionContext` from a document snapshot and a trigger.
///
/// The cursor position is read from the document, and the prefix is the contiguous run of word
/// characters (letters, digits, `_`, `$`) immediately before the cursor. The returned `range` is the document range that should
/// be replaced by the chosen completion.
public func makeCompletionContext(
    document: Document, trigger: RequestTrigger, invocationCount: Int = 1, mode: CompletionMode = .basic
) -> CompletionContext {
    let cursor = document.cursor
    let offset = cursor.position.utf16Offset
    let windowStart = max(0, offset - 256)
    let source = document.substring(utf16Offset: windowStart, length: max(0, offset - windowStart))
    let (prefix, localStart) = extractPrefixAndStart(before: (source as NSString).length, in: source)
    let startOffset = windowStart + localStart
    let start = TextPosition(
        line: cursor.position.line,
        column: max(0, cursor.position.column - (prefix as NSString).length),
        utf16Offset: startOffset
    )
    let range = TextRange(start: start, end: cursor.position)
    return CompletionContext(
        document: document,
        cursor: cursor,
        trigger: trigger,
        prefix: prefix,
        range: range,
        invocationCount: invocationCount,
        mode: mode
    )
}

private func extractPrefixAndStart(before offset: Int, in text: String) -> (String, Int) {
    let nsString = text as NSString
    var start = offset
    while start > 0 {
        let charIndex = start - 1
        let char = nsString.character(at: charIndex)
        if let scalar = UnicodeScalar(char), isCompletionIdentifierScalar(scalar) {
            start = charIndex
        } else {
            break
        }
    }
    return (nsString.substring(with: NSRange(location: start, length: offset - start)), start)
}

/// Characters that belong to an identifier for completion purposes: letters, digits, `_`, `$`.
public func isCompletionIdentifierScalar(_ scalar: UnicodeScalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
}
