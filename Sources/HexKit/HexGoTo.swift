import Foundation

public enum HexGoTo {
    /// Resolves `0x1F40`, a decimal, `+`/`-` relative to `caret`, or `end`.
    /// The result is clamped to `0...count` ( `count` is the position after the last byte).
    public static func resolve(_ text: String, caret: Int64, count: Int64) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased() == "end" { return max(0, count) }
        let sign: Int64
        let body: String
        if trimmed.hasPrefix("+") {
            sign = 1
            body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if trimmed.hasPrefix("-") {
            sign = -1
            body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else {
            sign = 0
            body = trimmed
        }
        guard let magnitude = absolute(body) else { return nil }
        let raw = sign == 0 ? magnitude : caret + sign * magnitude
        if raw < 0 { return 0 }
        if raw > count { return max(0, count) }
        return raw
    }

    private static func absolute(_ text: String) -> Int64? {
        guard !text.isEmpty else { return nil }
        let hex: Bool
        if text.lowercased().hasPrefix("0x") {
            hex = true
        } else {
            hex = text.contains { $0.isHexDigit && !$0.isNumber }
        }
        let digits = hex && text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }
        if !hex && digits.contains(where: { $0.isLetter }) { return nil }
        return Int64(digits, radix: hex ? 16 : 10)
    }
}
