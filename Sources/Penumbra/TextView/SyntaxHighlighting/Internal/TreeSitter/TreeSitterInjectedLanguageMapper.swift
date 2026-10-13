import Foundation

protocol TreeSitterInjectedLanguageMapperDelegate: AnyObject {
    func treeSitterInjectedLanguageMapper(_ mapper: TreeSitterInjectedLanguageMapper, textIn textRange: TreeSitterTextRange) -> String?
}

final class TreeSitterInjectedLanguageMapper {
    private enum CaptureName {
        static let language = "language"
        static let injectionLanguage = "injection.language"
    }

    private enum CaptureProperty {
        static let injectionLanguage = "injection.language"
        /// An ICU regular expression. Text it matches inside the injected node is left out of the
        /// injected parse (`{{name}}` in a JSON body), so the injected grammar never sees it.
        static let injectionExclude = "injection.exclude"
    }

    weak var delegate: TreeSitterInjectedLanguageMapperDelegate?

    private let captures: [TreeSitterCapture]
    private var languageNameToTextRangeMap: [String: [TreeSitterTextRange]] = [:]
    private var languageNamePendingContent: String?

    init(captures: [TreeSitterCapture]) {
        self.captures = captures
    }

    func map() -> [TreeSitterInjectedLanguage] {
        var result: [TreeSitterInjectedLanguage] = []
        for capture in captures {
            if capture.name == CaptureName.language || capture.name == CaptureName.injectionLanguage {
                languageNamePendingContent = nil
                if let text = delegate?.treeSitterInjectedLanguageMapper(self, textIn: capture.node.textRange) {
                    languageNamePendingContent = text
                }
            } else {
                let languageName = languageNamePendingContent ?? capture.properties[CaptureProperty.injectionLanguage] ?? capture.name
                let id = capture.node.rawValue.id!
                let textRange = capture.node.textRange
                languageNamePendingContent = nil
                var textRanges = [textRange]
                if let pattern = capture.properties[CaptureProperty.injectionExclude] {
                    textRanges = ranges(of: textRange, excluding: pattern)
                    // Nothing left to parse: an empty range list would mean "the whole document".
                    guard !textRanges.isEmpty else {
                        continue
                    }
                }
                result.append(TreeSitterInjectedLanguage(
                    id: id,
                    languageName: languageName,
                    textRange: textRange,
                    textRanges: textRanges
                ))
            }
        }
        return result
    }

    /// `textRange` minus every match of `pattern`, in order. Reads only the node's own text, so the
    /// cost follows the injected body, not the document. Offsets and columns are UTF-16 code units
    /// times two, and a row ends at `\n`, the way the parser counts them.
    private func ranges(of textRange: TreeSitterTextRange, excluding pattern: String) -> [TreeSitterTextRange] {
        guard let regex = Self.regularExpressions.regularExpression(for: pattern),
              let text = delegate?.treeSitterInjectedLanguageMapper(self, textIn: textRange) else {
            return [textRange]
        }
        let string = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: string.length))
            .filter { $0.range.length > 0 }
        guard !matches.isEmpty else {
            return [textRange]
        }
        var row = textRange.startPoint.row
        var column = textRange.startPoint.column
        var scanned = 0
        func point(at offset: Int) -> TreeSitterTextPoint {
            while scanned < offset {
                if string.character(at: scanned) == 0x0A {
                    row += 1
                    column = 0
                } else {
                    column += 2
                }
                scanned += 1
            }
            return TreeSitterTextPoint(row: row, column: column)
        }
        var pieces: [TreeSitterTextRange] = []
        func appendPiece(from start: Int, to end: Int) {
            guard end > start else {
                return
            }
            pieces.append(TreeSitterTextRange(
                startPoint: point(at: start),
                endPoint: point(at: end),
                startByte: ByteCount(textRange.startByte.value + start * 2),
                endByte: ByteCount(textRange.startByte.value + end * 2)
            ))
        }
        var cursor = 0
        for match in matches {
            appendPiece(from: cursor, to: match.range.location)
            cursor = max(cursor, match.range.location + match.range.length)
        }
        appendPiece(from: cursor, to: string.length)
        return pieces
    }

    private static let regularExpressions = RegularExpressionCache()
}

/// Compiled `injection.exclude` patterns. A query has a handful, and the mapper runs on every
/// edit, so each is compiled once.
private final class RegularExpressionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var compiled: [String: NSRegularExpression?] = [:]

    func regularExpression(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = compiled[pattern] {
            return cached
        }
        let regex = try? NSRegularExpression(pattern: pattern)
        compiled[pattern] = .some(regex)
        return regex
    }
}
