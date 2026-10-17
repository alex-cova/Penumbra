import Foundation

/// Host settings for command completion (`..`, and `.` in read-only files).
public struct CommandCompletionSettings: Hashable, Sendable, Codable {
    public var isEnabled: Bool
    /// Show commands as a separate, last section under a single `.`.
    public var showsSeparateGroup: Bool
    /// Allow `.` in a read-only file to open navigation commands.
    public var readOnlyEnabled: Bool

    public init(isEnabled: Bool = true, showsSeparateGroup: Bool = true, readOnlyEnabled: Bool = false) {
        self.isEnabled = isEnabled
        self.showsSeparateGroup = showsSeparateGroup
        self.readOnlyEnabled = readOnlyEnabled
    }

    public static let standard = CommandCompletionSettings()
}

/// Supplies command completion items for a context whose `commandMode` is set. Language
/// providers can conform too, to attach language-specific targets (`selecting:` ranges).
public protocol CommandCompletionProviding: CompletionProvider {
    func commandItems(context: CompletionContext) async -> [CompletionItem]
}

public extension CommandCompletionProviding {
    func provide(context: CompletionContext) async -> [CompletionItem] {
        guard context.commandMode != nil else { return [] }
        return await commandItems(context: context)
    }
}
