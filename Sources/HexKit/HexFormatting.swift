import Foundation

public enum HexOffsetBase: String, Sendable, CaseIterable {
    case hexadecimal
    case decimal
}

public enum HexPaneEncoding: String, Sendable, CaseIterable {
    case ascii
    case latin1
    case macRoman
    case cp437
    case windows1252

    public var displayName: String {
        switch self {
        case .ascii: "ASCII"
        case .latin1: "Latin-1"
        case .macRoman: "Mac Roman"
        case .cp437: "CP437"
        case .windows1252: "Windows-1252"
        }
    }

    public func glyph(for byte: UInt8) -> Character {
        glyphTable[Int(byte)]
    }

    fileprivate var glyphTable: [Character] {
        switch self {
        case .ascii: HexGlyphCache.ascii
        case .latin1: HexGlyphCache.latin1
        case .macRoman: HexGlyphCache.macRoman
        case .cp437: HexGlyphCache.cp437
        case .windows1252: HexGlyphCache.windows1252
        }
    }

    fileprivate var utf8Glyphs: [[UInt8]] {
        switch self {
        case .ascii: HexGlyphCache.asciiUTF8
        case .latin1: HexGlyphCache.latin1UTF8
        case .macRoman: HexGlyphCache.macRomanUTF8
        case .cp437: HexGlyphCache.cp437UTF8
        case .windows1252: HexGlyphCache.windows1252UTF8
        }
    }

    fileprivate func glyphUncached(_ byte: UInt8) -> Character {
        guard let scalar = scalar(for: byte) else { return "·" }
        if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
            return "·"
        }
        return Character(scalar)
    }

    /// The single byte this character encodes, or nil when it has no single-byte form.
    public func byte(for character: Character) -> UInt8? {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        switch self {
        case .ascii:
            return scalar.value <= 0x7F ? UInt8(scalar.value) : nil
        case .latin1:
            return scalar.value <= 0xFF ? UInt8(scalar.value) : nil
        case .macRoman:
            return HexEncodingTables.macRomanByte(scalar.value)
        case .cp437:
            return HexEncodingTables.cp437Byte(scalar.value)
        case .windows1252:
            return HexEncodingTables.windows1252Byte(scalar.value)
        }
    }

    private func scalar(for byte: UInt8) -> Unicode.Scalar? {
        switch self {
        case .ascii:
            return byte < 0x80 ? Unicode.Scalar(byte) : nil
        case .latin1:
            return Unicode.Scalar(byte)
        case .macRoman:
            return byte < 0x80 ? Unicode.Scalar(byte) : Unicode.Scalar(HexEncodingTables.macRoman[Int(byte) - 0x80])
        case .cp437:
            return byte < 0x80 ? Unicode.Scalar(byte) : Unicode.Scalar(HexEncodingTables.cp437[Int(byte) - 0x80])
        case .windows1252:
            if byte < 0x80 || byte >= 0xA0 { return Unicode.Scalar(byte) }
            let value = HexEncodingTables.windows1252[Int(byte) - 0x80]
            return value == 0 ? nil : Unicode.Scalar(value)
        }
    }
}

public enum HexByteClass: Sendable, Equatable {
    case nul
    case whitespace
    case control
    case printableASCII
    case high

    public static func classify(_ byte: UInt8) -> HexByteClass {
        if byte == 0 { return .nul }
        if byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C || byte == 0x20 { return .whitespace }
        if byte < 0x20 || byte == 0x7F { return .control }
        if byte < 0x80 { return .printableASCII }
        return .high
    }
}

public struct HexHit: Sendable, Equatable {
    public enum Pane: Sendable, Equatable {
        case hex(lowNibble: Bool)
        case text
    }

    public var byteIndex: Int
    public var pane: Pane

    public init(byteIndex: Int, pane: Pane) {
        self.byteIndex = byteIndex
        self.pane = pane
    }
}

/// Column geometry for one hex row. Positions are in points, origin at the left of the offset column.
public struct HexRowMetrics: Sendable, Equatable {
    public var bytesPerRow: Int
    public var groupSize: Int
    public var charWidth: Double
    public var offsetDigits: Int
    public var offsetGap: Double

    public init(bytesPerRow: Int, groupSize: Int, charWidth: Double, offsetDigits: Int, offsetGap: Double? = nil) {
        self.bytesPerRow = max(1, bytesPerRow)
        self.groupSize = max(1, groupSize)
        self.charWidth = charWidth
        self.offsetDigits = max(1, offsetDigits)
        self.offsetGap = offsetGap ?? charWidth * 2
    }

    public var hexOrigin: Double { Double(offsetDigits) * charWidth + offsetGap }

    /// One group of hex bytes plus the extra space that separates it from the next group.
    public var groupStride: Double { Double(groupSize * 3 + 1) * charWidth }

    public var groupCount: Int { max(1, (bytesPerRow + groupSize - 1) / groupSize) }

    public var textOrigin: Double { hexOrigin + Double(groupCount) * groupStride + charWidth }

    public var rowWidth: Double { textOrigin + Double(bytesPerRow) * charWidth }

    public func hexX(byte index: Int) -> Double {
        let group = index / groupSize
        let within = index % groupSize
        return hexOrigin + Double(group) * groupStride + Double(within) * 3 * charWidth
    }

    public func textX(byte index: Int) -> Double {
        textOrigin + Double(index) * charWidth
    }

    public func hitTest(x: Double) -> HexHit? {
        guard charWidth > 0 else { return nil }
        if x >= textOrigin {
            let index = Int((x - textOrigin) / charWidth)
            guard index >= 0, index < bytesPerRow else { return nil }
            return HexHit(byteIndex: index, pane: .text)
        }
        guard x >= hexOrigin else { return nil }
        let local = x - hexOrigin
        let stride = groupStride
        guard stride > 0 else { return nil }
        let group = Int(local / stride)
        let withinX = local - Double(group) * stride
        let byteWidth = 3 * charWidth
        var within = Int(withinX / byteWidth)
        var lowNibble = false
        if within >= groupSize {
            within = groupSize - 1
            lowNibble = true
        } else {
            let into = withinX - Double(within) * byteWidth
            lowNibble = into >= charWidth
        }
        let index = group * groupSize + within
        guard index >= 0, index < bytesPerRow else { return nil }
        return HexHit(byteIndex: index, pane: .hex(lowNibble: lowNibble))
    }
}

public enum HexLayout {
    public static func rowCount(byteCount: Int64, bytesPerRow: Int) -> Int64 {
        let width = Int64(max(1, bytesPerRow))
        guard byteCount > 0 else { return 0 }
        return (byteCount + width - 1) / width
    }

    public static func offsetDigits(byteCount: Int64, base: HexOffsetBase) -> Int {
        let last = max(0, byteCount > 0 ? byteCount - 1 : 0)
        let radix: Int64 = base == .hexadecimal ? 16 : 10
        var digits = 1
        var value = last
        while value >= radix {
            value /= radix
            digits += 1
        }
        return max(8, digits)
    }

    public static func formatOffset(_ offset: Int64, digits: Int, base: HexOffsetBase, uppercase: Bool) -> String {
        switch base {
        case .hexadecimal:
            if offset < 0 {
                let text = String(offset, radix: 16)
                let padded = String(repeating: "0", count: max(0, digits - text.count)) + text
                return uppercase ? padded.uppercased() : padded
            }
            return hexOffset(UInt64(offset), digits: max(0, digits), uppercase: uppercase)
        case .decimal:
            let text = String(max(0, offset))
            return String(repeating: " ", count: max(0, digits - text.count)) + text
        }
    }

    /// Largest multiple of 8 in 8...64 that fits `contentWidth`. The minimum is 8 even when it does not fit.
    public static func autoBytesPerRow(
        contentWidth: Double,
        charWidth: Double,
        groupSize: Int,
        offsetDigits: Int
    ) -> Int {
        guard charWidth > 0, contentWidth > 0 else { return 16 }
        var fit = 8
        var bytes = 8
        while bytes <= 64 {
            let width = HexRowMetrics(
                bytesPerRow: bytes,
                groupSize: groupSize,
                charWidth: charWidth,
                offsetDigits: offsetDigits
            ).rowWidth
            if width <= contentWidth { fit = bytes }
            bytes += 8
        }
        return fit
    }

    public static func formatHex(_ byte: UInt8, uppercase: Bool) -> String {
        uppercase ? HexDigitTables.upper[Int(byte)] : HexDigitTables.lower[Int(byte)]
    }

    public static func rowText(_ bytes: [UInt8], encoding: HexPaneEncoding) -> String {
        let glyphs = encoding.utf8Glyphs
        var utf8: [UInt8] = []
        utf8.reserveCapacity(bytes.count * 3)
        for byte in bytes {
            utf8.append(contentsOf: glyphs[Int(byte)])
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    private static func hexOffset(_ value: UInt64, digits: Int, uppercase: Bool) -> String {
        let alphabet = uppercase ? HexDigitTables.uppercaseNibbles : HexDigitTables.lowercaseNibbles
        var nibbleCount = 1
        var probe = value
        while probe >= 16 {
            probe >>= 4
            nibbleCount += 1
        }
        let width = max(digits, nibbleCount)
        var bytes = [UInt8](repeating: UInt8(ascii: "0"), count: width)
        var rest = value
        var index = width - 1
        while rest > 0 && index >= 0 {
            bytes[index] = alphabet[Int(rest & 0xF)]
            rest >>= 4
            index -= 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private enum HexDigitTables {
    static let lowercaseNibbles = Array("0123456789abcdef".utf8)
    static let uppercaseNibbles = Array("0123456789ABCDEF".utf8)
    static let lower: [String] = (0..<256).map { pair($0, alphabet: lowercaseNibbles) }
    static let upper: [String] = (0..<256).map { pair($0, alphabet: uppercaseNibbles) }

    private static func pair(_ byte: Int, alphabet: [UInt8]) -> String {
        String(decoding: [alphabet[byte >> 4], alphabet[byte & 0xF]], as: UTF8.self)
    }
}

private enum HexGlyphCache {
    static let ascii = table(.ascii)
    static let latin1 = table(.latin1)
    static let macRoman = table(.macRoman)
    static let cp437 = table(.cp437)
    static let windows1252 = table(.windows1252)
    static let asciiUTF8 = utf8Table(.ascii)
    static let latin1UTF8 = utf8Table(.latin1)
    static let macRomanUTF8 = utf8Table(.macRoman)
    static let cp437UTF8 = utf8Table(.cp437)
    static let windows1252UTF8 = utf8Table(.windows1252)

    private static func table(_ encoding: HexPaneEncoding) -> [Character] {
        (0..<256).map { encoding.glyphUncached(UInt8($0)) }
    }

    private static func utf8Table(_ encoding: HexPaneEncoding) -> [[UInt8]] {
        (0..<256).map { Array(String(encoding.glyphUncached(UInt8($0))).utf8) }
    }
}

public enum HexScrollerMap {
    public static func knobProportion(visibleRows: Double, totalRows: Double) -> Double {
        guard totalRows > 0 else { return 1 }
        return min(1, max(0, visibleRows / totalRows))
    }

    /// `fraction` is 0 at the top and 1 at the bottom of the track.
    public static func topRow(fraction: Double, visibleRows: Int64, totalRows: Int64) -> Int64 {
        let maxTop = max(0, totalRows - max(1, visibleRows))
        if maxTop == 0 { return 0 }
        let clamped = min(1, max(0, fraction))
        let row = (clamped * Double(maxTop)).rounded(.toNearestOrAwayFromZero)
        return min(maxTop, max(0, Int64(row)))
    }

    public static func fraction(topRow: Int64, visibleRows: Int64, totalRows: Int64) -> Double {
        let maxTop = max(0, totalRows - max(1, visibleRows))
        guard maxTop > 0 else { return 0 }
        return Double(min(max(0, topRow), maxTop)) / Double(maxTop)
    }
}

enum HexEncodingTables {
    static let cp437: [UInt32] = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
        0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
        0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
        0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
        0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
        0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
        0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
        0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
        0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
        0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
        0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0
    ]

    static let macRoman: [UInt32] = [
        0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
        0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
        0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
        0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
        0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
        0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
        0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
        0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
        0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
        0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
        0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
        0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
        0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
        0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
        0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
        0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7
    ]

    /// 0x80...0x9F. Zero marks a byte Windows-1252 leaves undefined.
    static let windows1252: [UInt32] = [
        0x20AC, 0x0000, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x0000, 0x017D, 0x0000,
        0x0000, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x0000, 0x017E, 0x0178
    ]

    static func cp437Byte(_ scalar: UInt32) -> UInt8? {
        if scalar <= 0x7F { return UInt8(scalar) }
        return cp437.firstIndex(of: scalar).map { UInt8($0 + 0x80) }
    }

    static func macRomanByte(_ scalar: UInt32) -> UInt8? {
        if scalar <= 0x7F { return UInt8(scalar) }
        return macRoman.firstIndex(of: scalar).map { UInt8($0 + 0x80) }
    }

    static func windows1252Byte(_ scalar: UInt32) -> UInt8? {
        if scalar <= 0x7F || (scalar >= 0xA0 && scalar <= 0xFF) { return UInt8(scalar) }
        return windows1252.firstIndex(of: scalar).map { UInt8($0 + 0x80) }
    }
}
