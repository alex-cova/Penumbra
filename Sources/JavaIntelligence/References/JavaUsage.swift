import Foundation

/// One place a symbol is declared or used.
public struct JavaUsage: Hashable, Sendable {
    public enum Kind: Sendable {
        case declaration, read, write, call, typeReference, `import`, constructorCall, methodReference
    }

    public enum Confidence: Sendable {
        case exact
        /// The overload or the receiver could not be pinned down; the usage may belong to a sibling.
        case ambiguous
    }

    public let url: URL
    /// UTF-8 byte range of the identifier in the file's text.
    public let byteRange: Range<Int>
    /// UTF-16 range of the identifier.
    public let utf16Range: NSRange
    /// Zero-based line and UTF-16 column of the identifier's start.
    public let line: Int
    public let column: Int
    /// The full text of the line holding the identifier, without its terminator.
    public let lineText: String
    public let kind: Kind
    public let confidence: Confidence

    public init(
        url: URL, byteRange: Range<Int>, utf16Range: NSRange, line: Int, column: Int, lineText: String,
        kind: Kind, confidence: Confidence
    ) {
        self.url = url
        self.byteRange = byteRange
        self.utf16Range = utf16Range
        self.line = line
        self.column = column
        self.lineText = lineText
        self.kind = kind
        self.confidence = confidence
    }
}

/// Builds ``JavaUsage`` values for byte ranges of one file's text.
struct JavaUsageLocator {
    let url: URL
    let text: String
    private let bytes: [UInt8]
    private let lineStarts: [Int]

    init(url: URL, text: String) {
        self.url = url
        self.text = text
        self.bytes = Array(text.utf8)
        var starts = [0]
        var index = 0
        while index < bytes.count {
            if bytes[index] == 10 {
                starts.append(index + 1)
            } else if bytes[index] == 13 {
                if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                starts.append(index + 1)
            }
            index += 1
        }
        self.lineStarts = starts
    }

    func usage(byteRange: Range<Int>, kind: JavaUsage.Kind, confidence: JavaUsage.Confidence) -> JavaUsage {
        let lower = min(byteRange.lowerBound, bytes.count)
        let upper = min(byteRange.upperBound, bytes.count)
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= lower { low = mid } else { high = mid - 1 }
        }
        let line = low
        let lineStart = lineStarts[line]
        var lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] : bytes.count
        while lineEnd > lineStart, bytes[lineEnd - 1] == 10 || bytes[lineEnd - 1] == 13 { lineEnd -= 1 }
        let lineText = String(decoding: bytes[lineStart..<max(lineStart, lineEnd)], as: UTF8.self)
        let prefix = String(decoding: bytes[lineStart..<lower], as: UTF8.self)
        let start16 = JavaNavigationText.utf16Offset(forByte: lower, in: text)
        let end16 = JavaNavigationText.utf16Offset(forByte: upper, in: text)
        return JavaUsage(
            url: url, byteRange: lower..<upper, utf16Range: NSRange(location: start16, length: end16 - start16),
            line: line, column: prefix.utf16.count, lineText: lineText, kind: kind, confidence: confidence
        )
    }
}
