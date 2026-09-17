import Foundation

/// The unit of text kept at full opacity while ``TextView/isFocusModeEnabled`` is on.
public enum FocusGranularity: Equatable {
    /// Only the sentence containing the caret (or touched by the selection) stays focused.
    case sentence
    /// The entire blank-line-delimited paragraph containing the caret (or touched by the
    /// selection) stays focused.
    case paragraph
}
