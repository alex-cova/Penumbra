import Foundation
import Runestone

/// Parse-and-apply for Umbra’s Go to Line command (Go menu, ⌘G, Find Action).
public enum GoToLineCommand {
    /// 1-based line number, or `nil` when the input is empty, non-numeric, or less than 1.
    public static func parse(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(trimmed), number >= 1 else { return nil }
        return number
    }

    /// Moves the active caret to the 1-based line in `raw`. Returns `false` without crashing
    /// for empty, non-numeric, or out-of-range input (`TextView.goToLine` rejects invalid rows).
    @MainActor
    @discardableResult
    public static func apply(_ raw: String, to textView: TextView) -> Bool {
        guard let number = parse(raw) else { return false }
        return textView.goToLine(number - 1)
    }
}
