import Foundation

/// The symbol under the caret that a rename would change.
public struct RenameTarget: Sendable {
    /// The identifier's range in the requesting document.
    public let range: TextRange
    public let currentName: String
    /// What is being renamed, for the prompt title ("class", "method"…).
    public let kindDescription: String?
    /// Returns a user-facing problem for an unacceptable new name, or `nil` when it is fine.
    /// Providers override this with their language's identifier rules.
    public let validate: @Sendable (String) -> String?

    public init(
        range: TextRange,
        currentName: String,
        kindDescription: String? = nil,
        validate: @escaping @Sendable (String) -> String? = RenameTarget.validateIdentifier
    ) {
        self.range = range
        self.currentName = currentName
        self.kindDescription = kindDescription
        self.validate = validate
    }

    /// Default rule: non-empty, starts with a letter, `_` or `$`, continues with letters, digits,
    /// `_` or `$`.
    @Sendable
    public static func validateIdentifier(_ name: String) -> String? {
        guard let first = name.unicodeScalars.first else { return "Enter a name" }
        func isStart(_ s: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(s) || s == "_" || s == "$" }
        guard isStart(first) else { return "A name must start with a letter, _ or $" }
        for scalar in name.unicodeScalars.dropFirst() where !(isStart(scalar) || CharacterSet.decimalDigits.contains(scalar)) {
            return "“\(String(scalar))” isn't allowed in a name"
        }
        return nil
    }

    /// Java package name: empty (default package) or dot-separated identifiers.
    @Sendable
    public static func validatePackageName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        for segment in trimmed.split(separator: ".") {
            if let problem = validateIdentifier(String(segment)) { return problem }
        }
        return nil
    }
}

/// Language-specific rename. The controller drives `prepareRename` → name prompt → `rename` →
/// preview; the host applies the resulting ``WorkspaceEdit``.
public protocol RenameProviding: Sendable {
    /// The symbol at the context's caret, or `nil` when nothing there can be renamed.
    func prepareRename(_ context: NavigationContext) async -> RenameTarget?
    /// Everything a rename to `newName` would change. Problems that forbid the rename are reported
    /// through ``WorkspaceEditPlan/blockingError``; throw only for unexpected failures.
    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan
}
