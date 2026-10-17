import Foundation

/// Something only the host application can do, named by an id the provider and the host
/// agree on. The editor passes it back to the host when the button is pressed.
public struct HoverAction: Sendable, Hashable {
    public let id: String
    public let title: String
    public let arguments: [String]

    public init(id: String, title: String, arguments: [String] = []) {
        self.id = id
        self.title = title
        self.arguments = arguments
    }
}

/// A single hover result produced by a provider.
///
/// `contents` is expected to be Markdown; the UI bridge can render it as needed.
public struct HoverResult: Sendable, CustomStringConvertible {
    public let contents: String
    public let range: TextRange?
    public let source: String
    /// Buttons the hover window draws under the text.
    public let actions: [HoverAction]

    public init(
        contents: String,
        range: TextRange? = nil,
        source: String,
        actions: [HoverAction] = []
    ) {
        self.contents = contents
        self.range = range
        self.source = source
        self.actions = actions
    }

    public var description: String {
        "Hover from \(source) over \(range.map { String(describing: $0) } ?? "unknown")"
    }
}
