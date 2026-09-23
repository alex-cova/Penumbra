import Foundation

/// Pre-processes the Enter key, like IntelliJ's `EnterHandlerDelegate`.
///
/// Delegates registered on ``TextView/enterHandlerDelegates`` run before the built-in handlers.
@MainActor
public protocol EnterHandlerDelegate: AnyObject {
    /// Returns the edit to perform for this Enter press, or `nil` to let the next handler try.
    func enterEdit(for context: EnterContext) -> EnterEdit?
}
