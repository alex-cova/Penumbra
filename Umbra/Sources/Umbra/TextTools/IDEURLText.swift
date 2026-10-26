import Foundation

/// Percent-encoding of editor text, like JavaScript's `encodeURIComponent`.
enum IDEURLText {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// `+` stays `+` (RFC 3986, not form encoding). `nil` for a malformed `%` sequence or bytes
    /// that are not UTF-8.
    static func decode(_ text: String) -> String? {
        text.removingPercentEncoding
    }
}
