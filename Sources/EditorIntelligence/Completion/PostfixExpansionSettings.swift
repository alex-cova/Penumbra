import Foundation

/// The key that expands a postfix template when the completion popup is closed.
public enum PostfixExpansionKey: String, Codable, Sendable, Hashable, CaseIterable {
    case tab
    case space
    case enter

    public var title: String {
        switch self {
        case .tab: return "Tab"
        case .space: return "Space"
        case .enter: return "Enter"
        }
    }

    /// What the key inserts when the word after the dot is not an enabled template.
    public var insertedText: String {
        switch self {
        case .tab: return "\t"
        case .space: return " "
        case .enter: return "\n"
        }
    }
}

/// Postfix expansion, as the editor sees it. The language provider owns which keys exist;
/// the controller only needs the enabled set so it can recognize the key without importing
/// a language module.
public struct PostfixExpansionSettings: Sendable, Equatable {
    public var isEnabled: Bool
    public var key: PostfixExpansionKey
    /// Template keys that expand on an exact match (`for`, not `fo`).
    public var templateKeys: Set<String>

    public init(isEnabled: Bool, key: PostfixExpansionKey, templateKeys: Set<String>) {
        self.isEnabled = isEnabled
        self.key = key
        self.templateKeys = templateKeys
    }

    public static let standard = PostfixExpansionSettings(isEnabled: true, key: .tab, templateKeys: [])
}
