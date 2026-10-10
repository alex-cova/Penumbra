import EditorIntelligence
import Foundation

/// One `file:line:column: severity: message` line of a Swift compiler's output.
struct SwiftBuildMessage: Sendable, Equatable {
    enum Severity: String, Sendable {
        case error, warning, note, remark
    }

    var file: String
    /// One-based, as the compiler prints them.
    var line: Int
    /// One-based, in UTF-8 bytes.
    var column: Int
    var severity: Severity
    var message: String
}

/// Reads `swift build` / `swift test` output for the problems the compiler reports. The same
/// diagnostic is printed once per compilation unit, so repeats are dropped.
enum SwiftBuildOutputParser {
    private static let pattern = try? NSRegularExpression(
        pattern: #"^(.+?\.swift):(\d+):(\d+): (error|warning|note|remark): (.*)$"#
    )

    static func parse(_ output: String) -> [SwiftBuildMessage] {
        guard let pattern else { return [] }
        var messages: [SwiftBuildMessage] = []
        var seen = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard let match = pattern.firstMatch(in: text, range: range), match.numberOfRanges == 6 else { continue }
            let ns = text as NSString
            guard let severity = SwiftBuildMessage.Severity(rawValue: ns.substring(with: match.range(at: 4))),
                  let lineNumber = Int(ns.substring(with: match.range(at: 2))),
                  let column = Int(ns.substring(with: match.range(at: 3))) else { continue }
            let message = SwiftBuildMessage(
                file: ns.substring(with: match.range(at: 1)), line: lineNumber, column: column,
                severity: severity, message: ns.substring(with: match.range(at: 5))
            )
            let key = "\(message.file):\(message.line):\(message.column):\(message.severity.rawValue):\(message.message)"
            if seen.insert(key).inserted { messages.append(message) }
        }
        return messages
    }

    /// Diagnostics per file. `textFor` supplies the file's current text (an open buffer, else disk) so
    /// the compiler's byte column lands on the right UTF-16 position. Remarks are dropped.
    static func diagnostics(
        from messages: [SwiftBuildMessage], baseDirectory: URL, textFor: (URL) -> String?
    ) -> [URL: [Diagnostic]] {
        var result: [URL: [Diagnostic]] = [:]
        var maps: [URL: SourceTextMap?] = [:]
        for message in messages where message.severity != .remark {
            let url = (message.file.hasPrefix("/")
                ? URL(fileURLWithPath: message.file)
                : baseDirectory.appendingPathComponent(message.file)).standardizedFileURL
            let map: SourceTextMap?
            if let known = maps[url] {
                map = known
            } else {
                map = textFor(url).map { SourceTextMap($0) }
                maps[url] = map
            }
            let range: EditorIntelligence.TextRange
            if let map, let start = map.byteOffset(line: message.line - 1, utf8Column: message.column - 1) {
                var end = start
                while end < map.utf8.count, isIdentifierByte(map.utf8[end]) { end += 1 }
                if end == start { end = min(start + 1, map.utf8.count) }
                range = map.range(bytes: start..<end)
            } else {
                let position = TextPosition(line: max(0, message.line - 1), column: max(0, message.column - 1), utf16Offset: 0)
                range = EditorIntelligence.TextRange(start: position, end: position)
            }
            let severity: DiagnosticSeverity
            switch message.severity {
            case .error: severity = .error
            case .warning: severity = .warning
            case .note, .remark: severity = .information
            }
            result[url, default: []].append(Diagnostic(
                severity: severity, message: message.message, range: range, source: "swiftc"
            ))
        }
        return result
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F || byte >= 0x80
    }
}
