import Foundation

/// A delimited text file as a table: the first record is the header. Pure and `Sendable`, so a
/// large buffer can be parsed off the main actor.
struct IDECSVTable: Sendable, Equatable {
    /// Most data rows kept; the rest of a larger file is dropped and `isTruncated` is set.
    static let maximumRows = 200_000

    var header: [String] = []
    var rows: [[String]] = []
    /// Zero-based line of the buffer each row starts on, parallel to `rows`.
    var sourceLines: [Int] = []
    var columnCount = 0
    var isTruncated = false
    var delimiter: Character = ","

    static let empty = IDECSVTable()

    /// The separator to use: tab for TSV; for CSV the most frequent of comma, semicolon and tab
    /// on the first line outside quotes (European exports use `;`), comma on a tie.
    static func delimiter(forIdentifier identifier: String?, sample: String) -> Character {
        if identifier == "tsv" { return "\t" }
        var counts: [UInt8: Int] = [0x2C: 0, 0x3B: 0, 0x09: 0]
        var inQuotes = false
        for byte in sample.utf8 {
            if byte == 0x22 {
                inQuotes.toggle()
            } else if !inQuotes {
                if byte == 0x0A || byte == 0x0D { break }
                if counts[byte] != nil { counts[byte, default: 0] += 1 }
            }
        }
        var best: UInt8 = 0x2C
        for candidate: UInt8 in [0x3B, 0x09] where counts[candidate, default: 0] > counts[best, default: 0] {
            best = candidate
        }
        return Character(UnicodeScalar(best))
    }

    /// RFC 4180: quoted fields may hold the delimiter, line breaks and `""`; `\n`, `\r\n` and a
    /// lone `\r` end a record; blank lines are skipped; short records are padded to the widest.
    static func parse(_ text: String, delimiter: Character) -> IDECSVTable {
        guard let delimiterByte = delimiter.asciiValue else { return .empty }
        let quote: UInt8 = 0x22
        let lineFeed: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        let bytes = Array(text.utf8)
        var records: [[String]] = []
        var lines: [Int] = []
        var record: [String] = []
        var field: [UInt8] = []
        var line = 0
        var recordLine = 0
        var inQuotes = false
        var atFieldStart = true
        var sawQuote = false
        var truncated = false

        func endField() {
            record.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            atFieldStart = true
        }

        /// Returns false once the row cap is exceeded.
        func endRecord() -> Bool {
            endField()
            defer {
                record.removeAll(keepingCapacity: true)
                sawQuote = false
            }
            if record.count == 1, record[0].isEmpty, !sawQuote { return true }
            records.append(record)
            lines.append(recordLine)
            return records.count <= maximumRows + 1
        }

        var index = 0
        let count = bytes.count
        scan: while index < count {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    if index + 1 < count, bytes[index + 1] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    if byte == lineFeed { line += 1 }
                    field.append(byte)
                }
            } else if byte == quote, atFieldStart {
                inQuotes = true
                sawQuote = true
                atFieldStart = false
            } else if byte == delimiterByte {
                endField()
            } else if byte == lineFeed || byte == carriageReturn {
                if byte == carriageReturn, index + 1 < count, bytes[index + 1] == lineFeed { index += 1 }
                if !endRecord() {
                    truncated = true
                    records.removeLast()
                    lines.removeLast()
                    break scan
                }
                line += 1
                recordLine = line
            } else {
                field.append(byte)
                atFieldStart = false
            }
            index += 1
        }
        if !truncated, !field.isEmpty || !record.isEmpty || sawQuote {
            if !endRecord() {
                truncated = true
                records.removeLast()
                lines.removeLast()
            }
        }

        guard let header = records.first else { return .empty }
        let width = records.reduce(0) { max($0, $1.count) }
        var rows = Array(records.dropFirst())
        for row in rows.indices where rows[row].count < width {
            rows[row].append(contentsOf: repeatElement("", count: width - rows[row].count))
        }
        var paddedHeader = header
        if paddedHeader.count < width {
            paddedHeader.append(contentsOf: repeatElement("", count: width - paddedHeader.count))
        }
        return IDECSVTable(
            header: paddedHeader,
            rows: rows,
            sourceLines: Array(lines.dropFirst()),
            columnCount: width,
            isTruncated: truncated,
            delimiter: delimiter
        )
    }
}
