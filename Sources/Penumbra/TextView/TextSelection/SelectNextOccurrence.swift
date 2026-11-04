import Foundation

/// Finds the next textual occurrence for multi-cursor "add next occurrence" commands.
enum SelectNextOccurrence {
    /// Word-boundary lookup at `location`. Only needs the document's UTF-16 `length` to clamp the
    /// starting position — the actual boundary walk is delegated entirely to `tokenizer`, which is
    /// already `StringView`-backed — so this never materializes document content.
    static func wordRange(at location: Int, documentLength: Int, tokenizer: EditorTextInputTokenizer) -> NSRange? {
        let position = IndexedPosition(index: min(max(location, 0), documentLength))
        let start = tokenizer.position(from: position, toBoundary: .word, inDirection: .backward) ?? position
        let end = tokenizer.position(from: position, toBoundary: .word, inDirection: .forward) ?? position
        guard let startIndex = (start as? IndexedPosition)?.index,
              let endIndex = (end as? IndexedPosition)?.index,
              endIndex > startIndex else {
            return nil
        }
        return NSRange(location: startIndex, length: endIndex - startIndex)
    }

    static func nextMatch(for query: String,
                          length: Int,
                          in string: NSString,
                          after location: Int,
                          caseSensitive: Bool = true) -> NSRange? {
        guard !query.isEmpty, length > 0 else {
            return nil
        }
        let start = min(max(location, 0), string.length)
        guard start < string.length else {
            return nil
        }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var searchLocation = start
        while searchLocation <= string.length - length {
            let searchRange = NSRange(location: searchLocation, length: string.length - searchLocation)
            let found = string.range(of: query, options: options, range: searchRange)
            guard found.location != NSNotFound else {
                return nil
            }
            if found.length == length {
                return found
            }
            searchLocation = found.location + max(found.length, 1)
        }
        return nil
    }

    /// Finds every occurrence of `query` in `string`, for select-all-occurrences (⌘⇧L).
    static func allMatches(for query: String, in string: NSString, caseSensitive: Bool = true) -> [NSRange] {
        guard !query.isEmpty else {
            return []
        }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var matches: [NSRange] = []
        var searchLocation = 0
        while searchLocation < string.length {
            let searchRange = NSRange(location: searchLocation, length: string.length - searchLocation)
            let found = string.range(of: query, options: options, range: searchRange)
            guard found.location != NSNotFound else {
                break
            }
            matches.append(found)
            searchLocation = found.location + max(found.length, 1)
        }
        return matches
    }

    // MARK: - Over a `FindTextSource`

    // The same searches over a ranged source, so a file-backed (piece-tree) buffer is read in
    // windows rather than copied into one string on the main thread (F20). The windowing and its
    // overlap come from `FindSearchEngine`'s literal enumerator, so a match across a window cut is
    // found; results equal the `NSString` versions above.

    static func nextMatch(for query: String,
                          length: Int,
                          in source: any FindTextSource,
                          after location: Int,
                          caseSensitive: Bool = true) -> NSRange? {
        guard !query.isEmpty, length > 0 else {
            return nil
        }
        let start = min(max(location, 0), source.utf16Length)
        guard start < source.utf16Length else {
            return nil
        }
        let options = FindSearchOptions(query: query, matchCase: caseSensitive)
        var next: NSRange?
        _ = FindSearchEngine.enumerateLiteralMatches(options: options, in: source, from: start) { found in
            // Like the `NSString` version, a match of another length (a canonically equivalent
            // spelling) is skipped.
            guard found.length == length else { return true }
            next = found
            return false
        }
        return next
    }

    static func allMatches(for query: String, in source: any FindTextSource, caseSensitive: Bool = true) -> [NSRange] {
        guard !query.isEmpty else {
            return []
        }
        let options = FindSearchOptions(query: query, matchCase: caseSensitive)
        var matches: [NSRange] = []
        _ = FindSearchEngine.enumerateLiteralMatches(options: options, in: source) { found in
            matches.append(found)
            return true
        }
        return matches
    }
}
