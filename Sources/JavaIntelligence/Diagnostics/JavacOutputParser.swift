import Foundation

/// One diagnostic from `javac`'s default (human-readable) output.
public struct JavacMessage: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case error
        case warning
    }

    /// The path exactly as `javac` printed it, or `nil` for a message that isn't about a file
    /// (`error: release version 99 not supported`).
    public let file: String?
    /// 1-based line, or `0` when there is no file.
    public let line: Int
    /// 0-based character column taken from the caret line, or `nil` when `javac` printed none.
    public let column: Int?
    public let severity: Severity
    /// The header text plus any continuation and detail lines (`symbol:`, `location:`), joined
    /// with newlines.
    public let message: String

    public init(file: String?, line: Int, column: Int?, severity: Severity, message: String) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
    }
}

/// Parses the text `javac` writes to stderr:
///
///     /path/Foo.java:5: error: cannot find symbol
///             Strin x;
///             ^
///       symbol:   class Strin
///       location: class Foo
///     1 error
///
/// The caret's index in its line is the 0-based column: `javac` pads the caret line with a tab
/// wherever the source line has one, so a character index lines up in both.
public enum JavacOutputParser {
    public static func parse(_ output: String) -> [JavacMessage] {
        let lines = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var messages: [JavacMessage] = []
        var index = 0
        while index < lines.count {
            guard let header = parseHeader(lines[index]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count, parseHeader(lines[end]) == nil, !isSummaryOrNote(lines[end]) {
                end += 1
            }
            messages.append(build(header, block: Array(lines[(index + 1)..<end])))
            index = end
        }
        return messages
    }

    private struct Header {
        let file: String?
        let line: Int
        let severity: JavacMessage.Severity
        let text: String
    }

    private static let fileHeader = try! NSRegularExpression(pattern: #"^(.+\.java):(\d+): (error|warning): (.*)$"#)
    private static let plainHeader = try! NSRegularExpression(pattern: #"^(error|warning): (.*)$"#)
    private static let summary = try! NSRegularExpression(pattern: #"^\d+ (error|warning)s?$"#)

    private static func parseHeader(_ line: String) -> Header? {
        let range = NSRange(line.startIndex..., in: line)
        if let match = fileHeader.firstMatch(in: line, range: range),
           let file = Range(match.range(at: 1), in: line),
           let number = Range(match.range(at: 2), in: line),
           let kind = Range(match.range(at: 3), in: line),
           let text = Range(match.range(at: 4), in: line),
           let lineNumber = Int(line[number]) {
            return Header(file: String(line[file]), line: lineNumber, severity: line[kind] == "error" ? .error : .warning, text: String(line[text]))
        }
        if let match = plainHeader.firstMatch(in: line, range: range),
           let kind = Range(match.range(at: 1), in: line),
           let text = Range(match.range(at: 2), in: line) {
            return Header(file: nil, line: 0, severity: line[kind] == "error" ? .error : .warning, text: String(line[text]))
        }
        return nil
    }

    private static func isSummaryOrNote(_ line: String) -> Bool {
        if line.hasPrefix("Note: ") { return true }
        return summary.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func build(_ header: Header, block: [String]) -> JavacMessage {
        var continuation: [String] = []
        var details: [String] = []
        var column: Int?

        if let caretIndex = block.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "^" }), caretIndex >= 1 {
            // Lines before the echoed source line continue the message; lines after the caret are
            // details such as `symbol:` / `location:`.
            continuation = Array(block[0..<(caretIndex - 1)])
            details = Array(block[(caretIndex + 1)...])
            column = block[caretIndex].firstIndex(of: "^").map { block[caretIndex].distance(from: block[caretIndex].startIndex, to: $0) }
        } else {
            details = block
        }

        let text = ([header.text] + continuation + details)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return JavacMessage(file: header.file, line: header.line, column: column, severity: header.severity, message: text)
    }
}
