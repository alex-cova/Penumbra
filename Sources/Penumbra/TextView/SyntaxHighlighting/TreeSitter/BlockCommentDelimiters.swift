import Foundation

/// The tokens that open and close a block comment, e.g. `/*` and `*/`. Drives
/// ``TextView/toggleBlockComment()``.
public struct BlockCommentDelimiters: Equatable, Sendable {
    public let open: String
    public let close: String

    public init(open: String, close: String) {
        self.open = open
        self.close = close
    }

    /// `/* … */`: C, C++, Java, Kotlin, Swift, Go, Rust, JavaScript, TypeScript, CSS, SQL.
    public static let cStyle = BlockCommentDelimiters(open: "/*", close: "*/")
    /// `<!-- … -->`: HTML, XML.
    public static let html = BlockCommentDelimiters(open: "<!--", close: "-->")
}
