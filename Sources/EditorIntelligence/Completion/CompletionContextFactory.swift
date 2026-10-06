import Foundation

/// Build a `CompletionContext` from a document snapshot and a trigger.
///
/// The cursor position is read from the document, and the prefix is the contiguous run of word
/// characters (letters, digits, `_`, `$`) immediately before the cursor. Inside `{{ }}` the run
/// also includes `.`, so `$random.uuid` is one token. The returned `range` is the document range
/// that should be replaced by the chosen completion.
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
    let end = min(max(offset, 0), nsString.length)
    let start = CompletionTokenScan.tokenStart(utf16Text: text, caret: end)
    return (nsString.substring(with: NSRange(location: start, length: end - start)), start)
}

/// Where a completion token starts, and whether a dot belongs to it.
///
/// `foo.bar` replaces `bar`. `{{$random.uuid}}` replaces from `$`, because `{{` (spaces and tabs
/// allowed) opens one template token. `{{host}}` is a template even though it has no dot.
public enum CompletionTokenScan {
    public static func tokenStart(utf16Text text: String, caret: Int) -> Int {
        let ns = text as NSString
        let end = min(max(caret, 0), ns.length)
        var cursor = end
        while cursor > 0 {
            let unit = ns.character(at: cursor - 1)
            guard let scalar = UnicodeScalar(unit) else { break }
            if isCompletionIdentifierScalar(scalar) || scalar == "." {
                cursor -= 1
                continue
            }
            break
        }
        if opensTemplate(utf16Text: text, tokenStart: cursor) {
            return cursor
        }
        var start = end
        while start > 0 {
            let unit = ns.character(at: start - 1)
            guard let scalar = UnicodeScalar(unit), isCompletionIdentifierScalar(scalar) else { break }
            start -= 1
        }
        return start
    }

    public static func opensTemplate(utf16Text text: String, tokenStart: Int) -> Bool {
        let ns = text as NSString
        var index = min(max(tokenStart, 0), ns.length)
        while index > 0 {
            let unit = ns.character(at: index - 1)
            if unit == 0x20 || unit == 0x09 {
                index -= 1
                continue
            }
            break
        }
        guard index >= 2 else { return false }
        return ns.character(at: index - 2) == 0x7B && ns.character(at: index - 1) == 0x7B
    }

    public static func suffixLength(utf16Text text: String, template: Bool) -> Int {
        let ns = text as NSString
        var length = 0
        while length < ns.length {
            let unit = ns.character(at: length)
            guard let scalar = UnicodeScalar(unit) else { break }
            if isCompletionIdentifierScalar(scalar) || (template && scalar == ".") {
                length += 1
                continue
            }
            break
        }
        return length
    }
}

/// Characters that belong to an identifier for completion purposes: letters, digits, `_`, `$`.
public func isCompletionIdentifierScalar(_ scalar: UnicodeScalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
}
