import Foundation

/// A purely lexical tokenizer that collects the identifiers (and keywords -- they are lexically
/// identical) of a Java source file. It skips line and block comments, string and char literals and
/// text blocks, so a name mentioned only in a comment or a string never makes its file a candidate.
/// No parse tree is needed, which keeps building the name index cheap.
///
/// Javadoc is skipped too: a `{@link Foo}` reference is not an identifier occurrence here. Rename
/// handles Javadoc separately.
public enum JavaIdentifierScanner {
    /// Every distinct identifier in `source`.
    public static func identifiers(in source: String) -> Set<String> {
        var result = Set<String>()
        var source = source
        source.withUTF8 { buffer in
            scan(buffer) { result.insert($0) }
        }
        return result
    }

    /// Whether `identifier` occurs as a token in `source` (outside comments and literals).
    public static func contains(_ identifier: String, in source: String) -> Bool {
        identifiers(in: source).contains(identifier)
    }

    private static func isIdentifierStart(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x24 || b >= 0x80
    }

    private static func isIdentifierPart(_ b: UInt8) -> Bool {
        isIdentifierStart(b) || (b >= 0x30 && b <= 0x39)
    }

    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>, emit: (String) -> Void) {
        let n = bytes.count
        var i = 0
        while i < n {
            let b = bytes[i]
            switch b {
            case 0x2F: // '/'
                if i + 1 < n, bytes[i + 1] == 0x2F {
                    i += 2
                    while i < n, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
                } else if i + 1 < n, bytes[i + 1] == 0x2A {
                    i += 2
                    while i < n {
                        if bytes[i] == 0x2A, i + 1 < n, bytes[i + 1] == 0x2F { i += 2; break }
                        i += 1
                    }
                } else {
                    i += 1
                }
            case 0x22: // '"'
                if i + 2 < n, bytes[i + 1] == 0x22, bytes[i + 2] == 0x22 {
                    i += 3
                    while i < n {
                        if bytes[i] == 0x5C { i += 2; continue }
                        if bytes[i] == 0x22, i + 2 < n, bytes[i + 1] == 0x22, bytes[i + 2] == 0x22 { i += 3; break }
                        i += 1
                    }
                } else {
                    i += 1
                    while i < n {
                        let c = bytes[i]
                        if c == 0x5C { i += 2; continue }
                        i += 1
                        // An unterminated string ends at the line break instead of eating the file.
                        if c == 0x22 || c == 0x0A { break }
                    }
                }
            case 0x27: // '\''
                i += 1
                while i < n {
                    let c = bytes[i]
                    if c == 0x5C { i += 2; continue }
                    i += 1
                    if c == 0x27 || c == 0x0A { break }
                }
            default:
                if isIdentifierStart(b) {
                    let start = i
                    i += 1
                    while i < n, isIdentifierPart(bytes[i]) { i += 1 }
                    emit(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self))
                } else if b >= 0x30 && b <= 0x39 {
                    // Numeric literal: swallow suffixes and hex digits (`0xFFL`, `1e3f`) so they
                    // don't read as identifiers.
                    i += 1
                    while i < n, isIdentifierPart(bytes[i]) || bytes[i] == 0x2E { i += 1 }
                } else {
                    i += 1
                }
            }
        }
    }
}
