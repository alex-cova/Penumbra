import Foundation

/// Manages the range history for progressive "extend selection" / "shrink selection"
/// (⌥↑ / ⌥↓ in the IntelliJ keymap).
///
/// It is purely a stack machine: `TextInputView` supplies the ordered list of candidate
/// ranges (word → syntax-node ancestors, or word → line → paragraph → document without a
/// tree), and this type tracks where in that ladder the selection currently sits. Any
/// selection change the controller didn't cause resets the ladder.
final class SemanticSelectionController {
    private var ladder: [NSRange] = []
    private var index = 0
    /// The selection this controller last applied; if the live selection differs, the ladder
    /// is stale.
    private var lastApplied: NSRange?

    /// Drops the ladder — call on any external selection change or text edit.
    func invalidate() {
        ladder = []
        index = 0
        lastApplied = nil
    }

    /// Expands the selection by one rung.
    /// - Parameters:
    ///   - current: the live primary selection.
    ///   - candidates: increasing ranges that each strictly contain `current`, smallest first.
    ///     Only evaluated when the ladder needs rebuilding.
    /// - Returns: the range to select, or `nil` if there's nothing larger.
    func expand(from current: NSRange, candidates: () -> [NSRange]) -> NSRange? {
        if lastApplied != current || ladder.isEmpty {
            rebuild(from: current, candidates: candidates())
        }
        guard index + 1 < ladder.count else {
            return nil
        }
        index += 1
        let range = ladder[index]
        lastApplied = range
        return range
    }

    /// Shrinks the selection by one rung. Only works while the ladder is still valid (i.e.
    /// the selection hasn't been touched since the last expand/shrink).
    func shrink(from current: NSRange) -> NSRange? {
        guard lastApplied == current, index > 0, index < ladder.count else {
            return nil
        }
        index -= 1
        let range = ladder[index]
        lastApplied = range
        return range
    }

    private func rebuild(from current: NSRange, candidates: [NSRange]) {
        var rungs: [NSRange] = [current]
        for candidate in candidates {
            guard let last = rungs.last else { break }
            // Strictly larger and enclosing the previous rung.
            if candidate.location <= last.location,
               candidate.upperBound >= last.upperBound,
               candidate.length > last.length {
                rungs.append(candidate)
            }
        }
        ladder = rungs
        index = 0
        lastApplied = current
    }
}
