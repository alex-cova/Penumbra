import Foundation

/// A typed edit reported to ``TextView/addTypingObserver(_:)`` observers after it was applied.
public enum TextViewTypingEvent: Equatable, Sendable {
    /// Text inserted by typing (or ``TextView/insertText(_:)``), before any auto-pairing.
    case inserted(String)
    /// A backward delete (⌫).
    case deletedBackward
}
