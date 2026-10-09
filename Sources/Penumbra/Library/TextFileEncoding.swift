import Foundation

/// A text encoding a file can be read or written in. The editor itself always holds UTF-8; a
/// file in another encoding is transcoded when it is opened and again when it is saved.
public struct TextFileEncoding: Hashable, Sendable, Identifiable {
    /// Stable key (`"utf8"`, `"cp1252"`, …) for settings and menus.
    public let id: String
    /// The name shown in menus, e.g. "Western (Windows 1252)".
    public let displayName: String
    /// The name shown in the status bar, e.g. "Windows-1252".
    public let shortName: String
    public let encoding: String.Encoding
    /// True when files in this encoding start with a byte-order mark that is written on save.
    public let byteOrderMark: Bool

    public static let utf8 = TextFileEncoding(
        id: "utf8", displayName: "UTF-8", shortName: "UTF-8", encoding: .utf8, byteOrderMark: false
    )
    public static let utf8WithBOM = TextFileEncoding(
        id: "utf8bom", displayName: "UTF-8 with BOM", shortName: "UTF-8 BOM", encoding: .utf8, byteOrderMark: true
    )
    public static let utf16LE = TextFileEncoding(
        id: "utf16le", displayName: "UTF-16 LE", shortName: "UTF-16 LE", encoding: .utf16LittleEndian, byteOrderMark: true
    )
    public static let utf16BE = TextFileEncoding(
        id: "utf16be", displayName: "UTF-16 BE", shortName: "UTF-16 BE", encoding: .utf16BigEndian, byteOrderMark: true
    )
    public static let windows1252 = TextFileEncoding(
        id: "cp1252", displayName: "Western (Windows 1252)", shortName: "Windows-1252",
        encoding: .windowsCP1252, byteOrderMark: false
    )

    /// Every encoding the editor offers, in menu order.
    public static let all: [TextFileEncoding] = [
        .utf8,
        .utf8WithBOM,
        .utf16LE,
        .utf16BE,
        TextFileEncoding(
            id: "latin1", displayName: "Western (ISO 8859-1)", shortName: "ISO-8859-1",
            encoding: .isoLatin1, byteOrderMark: false
        ),
        TextFileEncoding(
            id: "latin9", displayName: "Western (ISO 8859-15)", shortName: "ISO-8859-15",
            encoding: coreFoundation(.isoLatin9), byteOrderMark: false
        ),
        .windows1252,
        TextFileEncoding(
            id: "macroman", displayName: "Western (Mac OS Roman)", shortName: "Mac Roman",
            encoding: .macOSRoman, byteOrderMark: false
        ),
        TextFileEncoding(
            id: "cp1250", displayName: "Central European (Windows 1250)", shortName: "Windows-1250",
            encoding: .windowsCP1250, byteOrderMark: false
        ),
        TextFileEncoding(
            id: "cp1251", displayName: "Cyrillic (Windows 1251)", shortName: "Windows-1251",
            encoding: .windowsCP1251, byteOrderMark: false
        ),
        TextFileEncoding(
            id: "koi8r", displayName: "Cyrillic (KOI8-R)", shortName: "KOI8-R",
            encoding: coreFoundation(.KOI8_R), byteOrderMark: false
        ),
        TextFileEncoding(
            id: "shiftjis", displayName: "Japanese (Shift JIS)", shortName: "Shift JIS",
            encoding: .shiftJIS, byteOrderMark: false
        ),
        TextFileEncoding(
            id: "eucjp", displayName: "Japanese (EUC-JP)", shortName: "EUC-JP",
            encoding: .japaneseEUC, byteOrderMark: false
        ),
        TextFileEncoding(
            id: "gbk", displayName: "Chinese Simplified (GBK)", shortName: "GBK",
            encoding: coreFoundation(.GBK_95), byteOrderMark: false
        ),
        TextFileEncoding(
            id: "big5", displayName: "Chinese Traditional (Big5)", shortName: "Big5",
            encoding: coreFoundation(.big5), byteOrderMark: false
        ),
        TextFileEncoding(
            id: "euckr", displayName: "Korean (EUC-KR)", shortName: "EUC-KR",
            encoding: coreFoundation(.EUC_KR), byteOrderMark: false
        )
    ]

    public static func named(_ id: String) -> TextFileEncoding? {
        all.first { $0.id == id }
    }

    private static func coreFoundation(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        )
    }

    // MARK: - Byte-order marks

    private static let utf8Mark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LEMark: [UInt8] = [0xFF, 0xFE]
    private static let utf16BEMark: [UInt8] = [0xFE, 0xFF]

    /// The mark `encoding` files carry, when it has one.
    static func byteOrderMark(for encoding: String.Encoding) -> [UInt8]? {
        switch encoding {
        case .utf8: utf8Mark
        case .utf16LittleEndian: utf16LEMark
        case .utf16BigEndian: utf16BEMark
        default: nil
        }
    }

    /// The encoding a byte-order mark at the start of `prefix` announces, if there is one.
    /// A UTF-32 LE mark (`FF FE 00 00`) is not mistaken for UTF-16.
    public static func detect(byteOrderMarkIn prefix: Data) -> TextFileEncoding? {
        let bytes = [UInt8](prefix.prefix(4))
        if bytes.starts(with: utf8Mark) { return .utf8WithBOM }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return nil }
        if bytes.starts(with: utf16LEMark) { return .utf16LE }
        if bytes.starts(with: utf16BEMark) { return .utf16BE }
        return nil
    }

    /// `data` without the leading mark `encoding` uses, if it has one.
    static func removingByteOrderMark(from data: Data, encoding: String.Encoding) -> Data {
        guard let mark = byteOrderMark(for: encoding), data.starts(with: mark) else { return data }
        return data.dropFirst(mark.count)
    }

    // MARK: - Converting

    /// Decodes `data` (a leading byte-order mark is dropped). Nil when the bytes are not valid.
    public func decode(_ data: Data) -> String? {
        String(data: Self.removingByteOrderMark(from: data, encoding: encoding), encoding: encoding)
    }

    /// Encodes `string`, with the byte-order mark this encoding writes. Nil when a character has
    /// no representation in the encoding.
    public func encode(_ string: String) -> Data? {
        guard var data = string.data(using: encoding, allowLossyConversion: false) else { return nil }
        if byteOrderMark, let mark = Self.byteOrderMark(for: encoding) {
            data.insert(contentsOf: mark, at: 0)
        }
        return data
    }

    // MARK: - Guessing

    /// Best guess for the encoding of `sample` (the start of a file), for bytes that are not valid
    /// UTF-8. Returns nil for what looks like binary data. A byte-order mark wins; then UTF-16
    /// without one (every other byte zero); then Foundation's detector, with the Western
    /// single-byte guesses folded into Windows-1252, which is what such files nearly always are.
    public static func guess(from sample: Data) -> TextFileEncoding? {
        if let marked = detect(byteOrderMarkIn: sample) { return marked }
        let bytes = [UInt8](sample.prefix(8192))
        guard !bytes.isEmpty else { return .utf8 }

        let zeros = bytes.enumerated().filter { $0.element == 0 }
        if !zeros.isEmpty {
            let odd = zeros.filter { $0.offset % 2 == 1 }.count
            let even = zeros.count - odd
            let pairs = max(bytes.count / 2, 1)
            if odd * 3 > pairs, even * 10 < odd { return .utf16LE }
            if even * 3 > pairs, odd * 10 < even { return .utf16BE }
            return nil
        }

        var detected: NSString?
        let raw = NSString.stringEncoding(
            for: sample.prefix(1 << 20),
            encodingOptions: [.allowLossyKey: false],
            convertedString: &detected,
            usedLossyConversion: nil
        )
        let candidate = all.first { $0.encoding.rawValue == raw && $0.byteOrderMark == false }
        let western: Set<String.Encoding> = [.isoLatin1, .macOSRoman, .windowsCP1252]
        if let candidate, !western.contains(candidate.encoding), candidate != .utf8 {
            return candidate
        }
        return .windows1252
    }
}
