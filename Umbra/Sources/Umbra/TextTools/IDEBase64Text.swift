import Foundation

/// Base64 conversion of editor text, kept free of AppKit so it can be tested on its own.
enum IDEBase64Text {
    static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// Decodes Base64 text leniently: whitespace and line breaks are ignored, the URL-safe alphabet
    /// is accepted and missing padding is added. Returns `nil` when the text is not Base64 or the
    /// bytes are not UTF-8, so binary never lands in the buffer.
    static func decode(_ text: String) -> String? {
        var cleaned = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard !cleaned.isEmpty else { return nil }
        cleaned = cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = cleaned.count % 4
        if remainder == 1 { return nil }
        if remainder != 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
