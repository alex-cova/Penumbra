import Foundation
import UniformTypeIdentifiers

/// Decides whether a file should open as text, as hex, or only after a short content sniff.
///
/// Name checks never touch the disk. ``looksBinary(_:)`` looks only at the bytes it is given,
/// which the open path caps at 8 KB.
public enum BinaryContentDetector {
    public enum Classification: Equatable, Sendable {
        case text
        case binary
        case unknown
    }

    /// Extensions that are binary even when UniformTypeIdentifiers has no opinion.
    public static let binaryExtensions: Set<String> = [
        "class", "jar", "o", "a", "dylib", "so", "wasm", "bin", "dat", "db", "sqlite",
        "ttf", "otf", "woff", "woff2"
    ]

    /// By name only.
    public static func classify(_ url: URL) -> Classification {
        if LanguageIdentifier.identifier(for: url) != nil { return .text }
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), !ext.isEmpty {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
                || type.conforms(to: .xml) || type.conforms(to: .propertyList) {
                return .text
            }
            if isBinaryType(type) { return .binary }
        }
        if binaryExtensions.contains(ext) { return .binary }
        return .unknown
    }

    /// True when `head` (use the first 8 KB) should open as hex.
    public static func looksBinary(_ head: Data) -> Bool {
        let sample = [UInt8](head.prefix(8 * 1024))
        if sample.isEmpty { return false }
        if sample.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || sample.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return false
        }
        if TextFileEncoding.detect(byteOrderMarkIn: Data(sample.prefix(4))) != nil { return false }
        if describe(Data(sample)) != nil { return true }
        if sample.contains(0) {
            if isAlternatingUTF16(sample) { return false }
            return true
        }
        if controlRatioIsBinary(sample) { return true }
        if String(bytes: sample, encoding: .utf8) != nil { return false }
        if TextFileEncoding.guess(from: Data(sample)) != nil { return false }
        return true
    }

    /// A short label from a magic number, or nil when the head is unknown or truncated.
    public static func describe(_ head: Data) -> String? {
        let bytes = [UInt8](head.prefix(64))
        if bytes.starts(with: [0x7F, 0x45, 0x4C, 0x46]) { return "ELF" }
        if bytes.starts(with: [0xFE, 0xED, 0xFA, 0xCF]) || bytes.starts(with: [0xCF, 0xFA, 0xED, 0xFE]) {
            return "Mach-O 64-bit"
        }
        if bytes.starts(with: [0xFE, 0xED, 0xFA, 0xCE]) || bytes.starts(with: [0xCE, 0xFA, 0xED, 0xFE]) {
            return "Mach-O 32-bit"
        }
        if bytes.starts(with: [0xCA, 0xFE, 0xBA, 0xBE]) {
            if bytes.count >= 8 {
                let major = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
                if (45...70).contains(major) { return "Java class file" }
            }
            return "Mach-O fat"
        }
        if bytes.starts(with: [0xBE, 0xBA, 0xFE, 0xCA]) { return "Mach-O fat" }
        if bytes.starts(with: [0x4D, 0x5A]) { return "PE executable" }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04])
            || bytes.starts(with: [0x50, 0x4B, 0x05, 0x06])
            || bytes.starts(with: [0x50, 0x4B, 0x07, 0x08]) { return "ZIP archive" }
        if bytes.starts(with: [0x1F, 0x8B]) { return "gzip" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG image" }
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "PDF" }
        if bytes.starts(with: Array("SQLite format 3\u{0}".utf8)) { return "SQLite database" }
        if bytes.starts(with: [0x00, 0x61, 0x73, 0x6D]) { return "WebAssembly" }
        // `FLR\0`: a Java Flight Recorder file (the recording itself, not a chunk of one).
        if bytes.starts(with: [0x46, 0x4C, 0x52, 0x00]) { return "Java Flight Recording" }
        return nil
    }

    private static func isBinaryType(_ type: UTType) -> Bool {
        type.conforms(to: .executable) || type.conforms(to: .archive) || type.conforms(to: .audiovisualContent)
            || type.conforms(to: .pdf) || type.conforms(to: .font) || type.conforms(to: .database)
            || type.conforms(to: .diskImage) || type.conforms(to: .bundle)
    }

    private static func controlRatioIsBinary(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        var controls = 0
        for byte in bytes where isDisallowedControl(byte) {
            controls += 1
        }
        return controls * 100 > bytes.count
    }

    private static func isDisallowedControl(_ byte: UInt8) -> Bool {
        if byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C || byte == 0x1B { return false }
        return byte < 0x20 || byte == 0x7F
    }

    /// UTF-16 text without a BOM: more than half the pairs are zero on one side, and the other
    /// side is almost never zero. One stray NUL in a short head is not enough.
    private static func isAlternatingUTF16(_ bytes: [UInt8]) -> Bool {
        var odd = 0
        var even = 0
        for (offset, byte) in bytes.enumerated() where byte == 0 {
            if offset % 2 == 1 { odd += 1 } else { even += 1 }
        }
        let pairs = max(bytes.count / 2, 1)
        if odd * 2 > pairs, even * 10 < odd { return true }
        if even * 2 > pairs, odd * 10 < even { return true }
        return false
    }
}
