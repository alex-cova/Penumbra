import Foundation

struct TreeSitterInjectedLanguage {
    let id: UnsafeRawPointer
    let languageName: String
    /// The captured node's range.
    let textRange: TreeSitterTextRange
    /// What the injected parser reads: `textRange`, or its pieces when the pattern sets
    /// `injection.exclude` and part of the node matched it (never empty).
    let textRanges: [TreeSitterTextRange]

    /// `true` when `textRanges` is narrower than the node, so a later edit has to shift these
    /// ranges instead of reading the injected tree's root.
    var hasExcludedText: Bool {
        guard textRanges.count == 1, let only = textRanges.first else {
            return true
        }
        return only.startByte != textRange.startByte || only.endByte != textRange.endByte
    }
}
