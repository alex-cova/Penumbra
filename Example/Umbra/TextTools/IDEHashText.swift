import CryptoKit
import Foundation

/// Hex digests of the UTF-8 bytes of editor text.
enum IDEHashText {
    enum Algorithm: Sendable {
        case md5, sha1, sha256, sha512
    }

    /// Lowercase hex. The whole text is hashed, line breaks included. MD5 and SHA-1 are offered for
    /// checksums and legacy comparisons, not for security.
    static func hash(_ text: String, using algorithm: Algorithm) -> String {
        let data = Data(text.utf8)
        switch algorithm {
        case .md5: return hex(Insecure.MD5.hash(data: data))
        case .sha1: return hex(Insecure.SHA1.hash(data: data))
        case .sha256: return hex(SHA256.hash(data: data))
        case .sha512: return hex(SHA512.hash(data: data))
        }
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
