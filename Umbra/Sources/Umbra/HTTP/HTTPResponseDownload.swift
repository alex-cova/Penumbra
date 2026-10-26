import Foundation
import UniformTypeIdentifiers

/// A response that is not text (a spreadsheet, a PDF, an image…) cannot be read in the log, so it is
/// written to a file. A `>>` / `>>!` in the request still decides where it goes; this only fills the gap.
enum HTTPResponseDownload {
    private static let textSubtypes: Set<String> = [
        "json", "xml", "javascript", "ecmascript", "x-javascript", "x-www-form-urlencoded",
        "yaml", "x-yaml", "graphql", "csv", "html", "xhtml+xml", "toml", "sql", "x-sh",
    ]

    /// Text when the declared type says so; with no declared type, text when the bytes decode as UTF-8.
    static func isText(contentType: String?, data: Data) -> Bool {
        if data.isEmpty { return true }
        guard let contentType, !contentType.isEmpty else {
            return String(data: data, encoding: .utf8) != nil
        }
        let essence = contentType
            .split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let parts = essence.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return String(data: data, encoding: .utf8) != nil
        }
        if parts[0] == "text" { return true }
        if parts[0] != "application" { return false }
        let subtype = parts[1]
        if textSubtypes.contains(subtype) { return true }
        return subtype.hasSuffix("+json") || subtype.hasSuffix("+xml")
    }

    /// Where a non-text response goes, or `nil` when it is text.
    static func output(
        for response: HTTPURLResponse,
        data: Data,
        requestURL: URL,
        folder: URL
    ) -> HTTPResponseOutput? {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        guard !isText(contentType: contentType, data: data) else { return nil }
        let name = fileName(
            contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"),
            contentType: contentType,
            requestURL: requestURL
        )
        return HTTPResponseOutput(url: folder.appendingPathComponent(name), overwrite: false)
    }

    /// The server's `filename`, else the last path component of the URL, else `response`; always with an extension
    /// when the content type implies one, and never a path.
    static func fileName(contentDisposition: String?, contentType: String?, requestURL: URL) -> String {
        var name = contentDisposition.flatMap(dispositionFileName)
            ?? requestURL.lastPathComponent.removingPercentEncoding
            ?? ""
        name = sanitized(name)
        if name.isEmpty {
            name = "response"
        }
        if (name as NSString).pathExtension.isEmpty, let ext = fileExtension(forContentType: contentType) {
            name += "." + ext
        }
        return name
    }

    static func fileExtension(forContentType contentType: String?) -> String? {
        guard let contentType else { return "bin" }
        let essence = contentType
            .split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if essence.isEmpty || essence == "application/octet-stream" { return "bin" }
        return UTType(mimeType: essence)?.preferredFilenameExtension ?? "bin"
    }

    /// `filename*=UTF-8''…` wins over `filename="…"`.
    private static func dispositionFileName(_ header: String) -> String? {
        var plain: String?
        var extended: String?
        for field in splitFields(header).dropFirst() {
            guard let equals = field.firstIndex(of: "=") else { continue }
            let key = field[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = field[field.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "filename*" {
                if let quote = value.range(of: "''") {
                    value = String(value[quote.upperBound...])
                }
                extended = value.removingPercentEncoding ?? value
            } else if key == "filename" {
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                    value = value.replacingOccurrences(of: "\\\"", with: "\"")
                }
                plain = value
            }
        }
        return extended ?? plain
    }

    /// Splits on `;` outside quotes.
    private static func splitFields(_ header: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in header {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", inQuotes {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == ";", !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }

    /// Keeps the name inside the folder: no directories, no `:` (Finder shows it as `/`), no control characters,
    /// and no leading dot that would hide the file.
    static func sanitized(_ name: String) -> String {
        let lastComponent = name
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        let cleaned = String(lastComponent.unicodeScalars.map { scalar -> Character in
            if scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                return "-"
            }
            return Character(scalar)
        })
        var trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        if trimmed.utf8.count > 200 {
            let ext = (trimmed as NSString).pathExtension
            let stem = (trimmed as NSString).deletingPathExtension
            let kept = String(stem.prefix(120))
            trimmed = ext.isEmpty ? kept : kept + "." + ext
        }
        return trimmed
    }
}
