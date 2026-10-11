import Foundation

public enum HexCopyStyle: String, Sendable, CaseIterable {
    case hex
    case prefixed
    case cArray
    case base64
    case ascii
    case hexdump
    case swift
}

public enum HexCopy {
    public static func format(_ bytes: [UInt8], style: HexCopyStyle) -> String {
        switch style {
        case .hex:
            return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .prefixed:
            return bytes.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
        case .cArray:
            let body = bytes.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
            return "unsigned char bytes[] = { \(body) };"
        case .base64:
            return Data(bytes).base64EncodedString()
        case .ascii:
            return String(bytes.map { byte in
                (byte >= 0x20 && byte < 0x7F) ? Character(Unicode.Scalar(byte)) : "."
            })
        case .hexdump:
            return hexdump(bytes)
        case .swift:
            let body = bytes.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
            return "[\(body)]"
        }
    }

    /// Hex with separators and `0x` prefixes, or the original string's UTF-8 when that is not hex.
    public static func parsePaste(_ string: String) -> [UInt8] {
        if string.isEmpty { return [] }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;{}[]"))
        let tokens = string.components(separatedBy: separators).filter { !$0.isEmpty }
        if let parsed = parseTokens(tokens) { return parsed }
        return Array(string.utf8)
    }

    private static func parseTokens(_ tokens: [String]) -> [UInt8]? {
        guard !tokens.isEmpty else { return [] }
        var out: [UInt8] = []
        for token in tokens {
            var body = token
            if body.lowercased().hasPrefix("0x") { body.removeFirst(2) }
            guard !body.isEmpty, body.allSatisfy(\.isHexDigit) else { return nil }
            if body.count == 1 {
                guard let value = UInt8(body, radix: 16) else { return nil }
                out.append(value)
                continue
            }
            guard body.count.isMultiple(of: 2) else { return nil }
            var index = body.startIndex
            while index < body.endIndex {
                let next = body.index(index, offsetBy: 2)
                guard let value = UInt8(body[index..<next], radix: 16) else { return nil }
                out.append(value)
                index = next
            }
        }
        return out
    }

    private static func hexdump(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            let slice = Array(bytes[offset..<end])
            var hex = ""
            for (index, byte) in slice.enumerated() {
                if index == 8 { hex += " " }
                if index > 0 { hex += " " }
                hex += String(format: "%02x", byte)
            }
            if hex.count < 50 { hex += String(repeating: " ", count: 50 - hex.count) }
            let ascii = slice.map { byte -> Character in
                (byte >= 0x20 && byte < 0x7F) ? Character(Unicode.Scalar(byte)) : "."
            }
            let address = String(format: "%08x", offset)
            lines.append("\(address)  \(hex)|\(String(ascii))|")
            offset = end
        }
        lines.append(String(format: "%08x", bytes.count))
        return lines.joined(separator: "\n")
    }
}
