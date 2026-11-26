import AppKit
import DatabaseKit
import Foundation

/// The ways the inspector can show one value. Which are offered depends on what the value is,
/// never on guessing: a viewer appears only when the content parses as that format.
enum IDEDatabaseValueFormat: String, CaseIterable, Identifiable, Sendable {
    case text = "Text", json = "JSON", xml = "XML", hex = "Hex", image = "Image"
    var id: Self { self }
}

enum IDEDatabaseValueFormats {
    /// The most bytes or characters a viewer renders. A larger value is cut with a note, so the
    /// inspector's cost is bounded by this, not by the value.
    static let renderLimit = 64 * 1_024
    static let imageLimit = 16 * 1_024 * 1_024

    struct Rendered: Equatable {
        var text: String
        var note: String?
    }

    static func available(for cell: DatabaseValue) -> [IDEDatabaseValueFormat] {
        var formats: [IDEDatabaseValueFormat] = [.text]
        switch cell {
        case .bytes(let count, let prefix):
            formats = [.hex]
            if utf8Text(prefix, complete: prefix.count == count) != nil { formats.append(.text) }
            if prefix.count == count, imageType(prefix) != nil { formats.insert(.image, at: 0) }
        case .json, .bson:
            formats = [.json, .text]
        case .text, .truncated:
            let text = sourceText(cell)
            if looksLikeJSON(text), IDEJSONText.format(text) != nil { formats.append(.json) }
            if looksLikeXML(text), prettyXML(text) != nil { formats.append(.xml) }
        default: break
        }
        return formats
    }

    static func render(_ cell: DatabaseValue, as format: IDEDatabaseValueFormat) -> Rendered {
        switch (format, cell) {
        case (.hex, .bytes(let count, let prefix)):
            var note = prefix.count < count ? "First \(prefix.count.formatted()) of \(count.formatted()) bytes. Load the full value for the rest." : nil
            if prefix.count > renderLimit { note = "Showing the first \(renderLimit.formatted()) of \(count.formatted()) bytes." }
            return Rendered(text: hexDump(prefix, limit: renderLimit), note: note)
        case (.text, .bytes(let count, let prefix)):
            let text = utf8Text(prefix, complete: prefix.count == count) ?? ""
            return Rendered(text: bounded(text), note: "Binary data read as UTF-8")
        case (.json, _):
            let text = sourceText(cell)
            return Rendered(text: bounded(IDEJSONText.format(text) ?? text), note: nil)
        case (.xml, _):
            let text = sourceText(cell)
            return Rendered(text: bounded(prettyXML(text) ?? text), note: nil)
        default:
            return Rendered(text: bounded(sourceText(cell)), note: nil)
        }
    }

    /// What Copy puts on the pasteboard: the whole value, not the bounded rendering.
    static func copyText(_ cell: DatabaseValue, as format: IDEDatabaseValueFormat) -> String {
        let text = sourceText(cell)
        switch format {
        case .json: return IDEJSONText.format(text) ?? text
        case .xml: return prettyXML(text) ?? text
        case .hex:
            if case .bytes(_, let prefix) = cell { return hexDump(prefix, limit: imageLimit) }
            return text
        case .text, .image:
            if case .bytes(let count, let prefix) = cell { return utf8Text(prefix, complete: prefix.count == count) ?? hexDump(prefix, limit: imageLimit) }
            return text
        }
    }

    /// `offset  00 01 …  |ascii|` rows of sixteen bytes, at most `limit` bytes.
    static func hexDump(_ bytes: [UInt8], limit: Int) -> String {
        var lines: [String] = []
        let shown = bytes.prefix(limit)
        var offset = 0
        while offset < shown.count {
            let chunk = shown[(shown.startIndex + offset)..<min(shown.endIndex, shown.startIndex + offset + 16)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = String(chunk.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08X  ", offset) + padded + "  |" + ascii + "|")
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    /// The image format a complete value starts as, from its magic bytes.
    static func imageType(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 12, bytes.count <= imageLimit else { return nil }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "PNG" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "JPEG" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "GIF" }
        if bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "WebP" }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "TIFF" }
        return nil
    }

    static func image(_ cell: DatabaseValue) -> NSImage? {
        guard case .bytes(let count, let prefix) = cell, prefix.count == count, imageType(prefix) != nil else { return nil }
        return NSImage(data: Data(prefix))
    }

    static func prettyXML(_ text: String) -> String? {
        guard text.utf8.count <= 1_048_576, let data = text.data(using: .utf8) else { return nil }
        // External entities are never loaded: a value from a database is not a trusted document.
        guard let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePrettyPrint]) else {
            return nil
        }
        return String(data: document.xmlData(options: .nodePrettyPrint), encoding: .utf8)
    }

    // MARK: Helpers

    private static func sourceText(_ cell: DatabaseValue) -> String {
        switch cell {
        case .truncated(let preview, _): preview
        case .json(let text), .bson(_, let text): text
        default: cell.rawText ?? ""
        }
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.drop(while: { $0.isWhitespace }).first else { return false }
        return first == "{" || first == "["
    }

    private static func looksLikeXML(_ text: String) -> Bool {
        text.drop(while: { $0.isWhitespace }).first == "<"
    }

    private static func utf8Text(_ bytes: [UInt8], complete: Bool) -> String? {
        guard !bytes.isEmpty, bytes.count <= renderLimit * 4 else { return nil }
        var candidate = bytes
        // A partial value may end inside a character; ignore at most three trailing bytes then.
        if !complete { for _ in 0..<3 where String(validatingCString: candidate.map { CChar(bitPattern: $0) } + [0]) == nil { candidate.removeLast() } }
        guard let text = String(bytes: candidate, encoding: .utf8), !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }
        return text
    }

    private static func bounded(_ text: String) -> String {
        guard text.utf8.count > renderLimit else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: renderLimit)
        while end > text.utf8.startIndex, text.utf8[end] & 0xC0 == 0x80 { end = text.utf8.index(before: end) }
        return String(text[..<end]) + "\n… \(text.utf8.count.formatted()) bytes in all; the viewer shows the first \(renderLimit.formatted())."
    }
}
