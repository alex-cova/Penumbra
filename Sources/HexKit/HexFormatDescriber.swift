import Foundation

/// A short format name from the leading bytes, plus one header field for Mach-O, ELF and ZIP.
public enum HexFormatDescriber {
    public static func label(head: [UInt8], tail: [UInt8] = []) -> String? {
        guard let kind = kind(of: head) else { return nil }
        switch kind {
        case .machO32(let endian):
            return cpuLabel(head, bits: "32-bit", endian: endian) ?? "Mach-O 32-bit"
        case .machO64(let endian):
            return cpuLabel(head, bits: "64-bit", endian: endian) ?? "Mach-O 64-bit"
        case .machOFat:
            return "Mach-O fat"
        case .javaClass(let major):
            return "Java class \(major)"
        case .elf:
            return elfLabel(head) ?? "ELF"
        case .pe:
            return "PE executable"
        case .zip:
            if let entries = zipEntries(tail) { return "ZIP archive (\(entries) entries)" }
            return "ZIP archive"
        case .gzip:
            return "gzip"
        case .png:
            return "PNG image"
        case .pdf:
            return "PDF"
        case .sqlite:
            return "SQLite database"
        case .wasm:
            return "WebAssembly"
        }
    }

    /// Reads at most 64 bytes from the front and, for a ZIP, one tail of at most 64 KB + 22 bytes.
    public static func label(source: any HexByteSource) -> String? {
        var head = [UInt8](repeating: 0, count: 64)
        let headCount = (try? head.withUnsafeMutableBytes { raw in try source.read(0..<64, into: raw) }) ?? 0
        let prefix = Array(head.prefix(headCount))
        guard kind(of: prefix) != nil else { return nil }
        var tail: [UInt8] = []
        if case .zip = kind(of: prefix), source.count > 0 {
            let tailCount = min(source.count, 65_536 + 22)
            let start = source.count - tailCount
            var buffer = [UInt8](repeating: 0, count: Int(tailCount))
            let got = (try? buffer.withUnsafeMutableBytes { raw in
                try source.read(start..<source.count, into: raw)
            }) ?? 0
            tail = Array(buffer.prefix(got))
        }
        return label(head: prefix, tail: tail)
    }

    private enum Kind {
        case machO32(little: Bool)
        case machO64(little: Bool)
        case machOFat
        case javaClass(UInt16)
        case elf
        case pe
        case zip
        case gzip
        case png
        case pdf
        case sqlite
        case wasm
    }

    private static func kind(of head: [UInt8]) -> Kind? {
        if head.starts(with: [0x7F, 0x45, 0x4C, 0x46]) { return .elf }
        if head.starts(with: [0xFE, 0xED, 0xFA, 0xCF]) { return .machO64(little: false) }
        if head.starts(with: [0xCF, 0xFA, 0xED, 0xFE]) { return .machO64(little: true) }
        if head.starts(with: [0xFE, 0xED, 0xFA, 0xCE]) { return .machO32(little: false) }
        if head.starts(with: [0xCE, 0xFA, 0xED, 0xFE]) { return .machO32(little: true) }
        if head.starts(with: [0xCA, 0xFE, 0xBA, 0xBE]) {
            if head.count >= 8 {
                let major = UInt16(head[6]) << 8 | UInt16(head[7])
                if (45...70).contains(major) { return .javaClass(major) }
            }
            return .machOFat
        }
        if head.starts(with: [0xBE, 0xBA, 0xFE, 0xCA]) { return .machOFat }
        if head.starts(with: [0x4D, 0x5A]) { return .pe }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04])
            || head.starts(with: [0x50, 0x4B, 0x05, 0x06])
            || head.starts(with: [0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if head.starts(with: [0x1F, 0x8B]) { return .gzip }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
        if head.starts(with: Array("SQLite format 3\u{0}".utf8)) { return .sqlite }
        if head.starts(with: [0x00, 0x61, 0x73, 0x6D]) { return .wasm }
        return nil
    }

    private static func cpuLabel(_ head: [UInt8], bits: String, endian little: Bool) -> String? {
        guard head.count >= 8 else { return "Mach-O \(bits)" }
        let cpu = UInt32(unsigned(head[4..<8], little: little))
        let name: String
        switch cpu {
        case 7: name = "i386"
        case 0x0100_0007: name = "x86-64"
        case 12: name = "arm"
        case 0x0100_000C: name = "arm64"
        default: return "Mach-O \(bits)"
        }
        return "Mach-O \(bits) \(name)"
    }

    private static func elfLabel(_ head: [UInt8]) -> String? {
        guard head.count >= 20, head.count > 5 else { return "ELF" }
        let bits = head[4] == 2 ? "64-bit" : head[4] == 1 ? "32-bit" : nil
        let little = head[5] == 1
        guard head[5] == 1 || head[5] == 2 else { return bits.map { "ELF \($0)" } ?? "ELF" }
        let machine = UInt16(unsigned(head[18..<20], little: little))
        let name: String
        switch machine {
        case 3: name = "x86"
        case 62: name = "x86-64"
        case 40: name = "ARM"
        case 183: name = "AArch64"
        default:
            if let bits { return "ELF \(bits)" }
            return "ELF"
        }
        if let bits { return "ELF \(bits) \(name)" }
        return "ELF \(name)"
    }

    private static func zipEntries(_ tail: [UInt8]) -> Int? {
        guard tail.count >= 22 else { return nil }
        var index = tail.count - 22
        let floor = max(0, tail.count - (22 + 65_535))
        while index >= floor {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                return Int(tail[index + 10]) | (Int(tail[index + 11]) << 8)
            }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }

    private static func unsigned(_ bytes: ArraySlice<UInt8>, little: Bool) -> UInt64 {
        var value: UInt64 = 0
        if little {
            for (offset, byte) in bytes.enumerated() {
                value |= UInt64(byte) << (offset * 8)
            }
        } else {
            for byte in bytes { value = (value << 8) | UInt64(byte) }
        }
        return value
    }
}
