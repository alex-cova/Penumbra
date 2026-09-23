import Foundation

/// Known emphasis group identifiers used by built-in editor features.
public enum EmphasisGroup {
    public static let brackets = "penumbra.bracketPairs"
    public static let find = "penumbra.find"
    public static let diagnostics = "penumbra.diagnostics"
    public static let occurrences = "penumbra.occurrences"
    /// Cmd-hover underline for a symbol that can be navigated to.
    public static let navigation = "penumbra.navigation"
}
